# Polishing Roadmap — ESP32 + Swift App
> Goal: fully polished experience before migrating UI to UIKit.
> Items ordered by impact.
some bugs i forgot to put in this idk if they r solved  (4-byte cache key truncation, awaitWriteWindow lost-wakeup race, the two timeout-task continuation races, the drawHorizontalSplit/drawBarnDoors comment-vs-code mismatch, the per-pixel SPI in the diagonal/circular transitions)
---

## GitHub Current Focus (April 2026)

### Done recently
- Live debug line is single-line + persistent (shows current phase, then last state).
- Live phase text is color-coded by phase type.
- Top `Sent new` / board ACK / transition badges now clear on song skip and on nothing playing, then repopulate only when new transfer/cache-hit completes.
- Playback controls remain visible while paused.
- "Paused" state is shown when track metadata exists but playback is not active.
- Transfer/debug timings are shown in seconds.

### Next priority (high)
- **Cache-check speed must be faster** for real-world usage where many songs are already on device.
- Use **firmware-side optimization first**:
  - Speed up SD cache lookup/index in `main.cpp`.
  - Treat album-id-aware cache key behavior as part of this optimization path.
- Add before/after timing notes in this file once implemented.

### Active now
- **More transitions** (ESP32) is active and should be worked before lower-priority nice-to-have items.
- Buy a new battery for the device/hardware setup.
- Fix brightness control reliability (it sometimes does not change on hardware).
- Fix clear-cache reliability (sometimes cache delete does not apply/reflect in app).
- Check code in Claude inside Xcode and compare findings with this roadmap.
- Continue bug hunt to reduce occasional transfer timeouts / unsuccessful sends.
- Fix pause/unpause behavior so same track is not miscounted as a new cache/download event; keep debug output accurate and show explicit write-confirmed state.
- Fix album-art preview sizing jump in app (image grows during download then shrinks after pipeline settles); keep a consistent frame size through loading and completion.
- Fix app layout so album art / content uses full intended screen space consistently.
- Fix remaining false cache-hit scenarios under rapid skip/reconnect paths.
- Fix stale partial-frame flash on skip (old image draws briefly before correct next song).

### End-of-session issue capture (2026-04-15)
- App: cover art can resize during download and then return to normal.
- App: UI still does not fill the entire screen consistently.
- Cache: occasional false cache-hit state still observed.
- Transfer: on skip, a portion of the previous image can render briefly before the correct next song.

## ESP32 / `main.cpp` — laptop backlog (git + flash here)

Do these on the machine where your **known-good** `src/main.cpp` lives; push before/after each logical chunk. Update [`docs/BLE_PROTOCOL.md`](docs/BLE_PROTOCOL.md) whenever GATT or file formats change.

| Roadmap item | File / area | What to change (high level) |
|--------------|---------------|------------------------------|
| **2** Fix dither + drop redraw | `loop()` ~transfer complete | Once iOS dithers correctly during quantization, remove `applyFloydSteinbergDithering` and the full-screen `drawImageLineByLine` redraw after `imageTransferComplete` — the progressive-draw path already drew every row as data arrived. Just save to cache and ACK. |
| **7** BLE brightness | GATT setup + new UUID `0000ffe5-…` | One-byte write → `ledcWrite(TFT_BL, value)` (replace fixed `TFT_BRIGHTNESS_MAX`). Swift: `BLEManager.setBrightness`, Settings slider, `UserDefaults`. |
| **9** CRC32 on cache | `saveToCache` / cache load path | After `IMAGE_SIZE` bytes, append 4-byte CRC32; on load recompute and delete + miss if mismatch. |
| **11** More transitions | Transition switch / helpers | Add `drawXxx` + enum + name string (pixel rain, spiral, etc.). |
| **12** iOS-picked transition | Image header / BLE parser | First byte transition index + existing 4-byte LE size (5-byte header); `0xFF` = random. Parse in firmware image receive state machine. |
| **14** Clear SD from app | Cache characteristic handler | Magic `0xCAC4E1EA` → delete `/cache/*.bin`, reply on message char. |
| **15** Album ID cache key | Cache key derivation | Replace or dual MD5(image URL) with stable album id from app; align 16-byte key layout with iOS. |
| **16** Gamma + tuning | After `gfx->begin()` | ST7789 `0xE0` / `0xE1` gamma register blocks via `bus->writeCommand()`; tune on hardware. Optional: compare dither variants in firmware **or** only on iOS once dither moves off device. |
| **19** GIF animation | New BLE mode + `loop()` | New packet magic; multi-frame `/anim/*.bin`; cycle with `millis()` and frame delay. |

**Already in your `main.cpp`:** `PROPERTY_WRITE_NR` on image char, cache check, progressive line draw, stats request handling. (FS dither path is still present but will be removed once item 2 lands.)

---

## PRIORITY 1 — Core experience

### 2. Fix Floyd-Steinberg dithering, REPLACE WITH ATKISONS — currently a no-op *(ESP32 + Swift)*
**Critical bug:** the current `applyFloydSteinbergDitheringRGB565` in `ImageProcessor.swift` (and the firmware version it was ported from) operates on the *already-quantized* RGB565 buffer. Since `oldR = ((pixel >> 11) & 0x1F) << 3` and `newR = (oldR >> 3) << 3` are mathematically equal, `errR == 0` for every pixel and no error ever propagates. The function burns CPU and produces output identical to its input.

**Fix:** dither *during* quantization, not after. Rewrite so the F-S pass operates on the full 8-bit RGB buffer (the `raw` array inside `packRGB565LittleEndian`), and write out the 5/6/5 quantized value as you go. Error term is `(8bit_value - dequantized_5/6/5_value)`, propagated to the standard F-S neighbors. This also halves the memory traffic vs. a separate pass.

**ESP32 side:** once iOS dithers correctly, remove `applyFloydSteinbergDithering()` and the `drawImageLineByLine` redraw after `imageTransferComplete` in `loop()`. The progressive-draw path already drew every row as data arrived — the second top-to-bottom redraw is pure waste.

---

### 3. Fix color grading, GAMMA  and stuff—  *(Swift)*
idk but needs to be fixed dont use old python values

**TODO:** review ST7789VW datasheet + Waveshare gamma reference notes in `resources/` and reconcile the iOS grading values 
- Add `CIColorClamp` *before* gamma/saturation/contrast filters so the clamp limits the headroom your grading wants to use.
- Reconcile contrast/brightness/saturation numbers against the Python pipeline (values TBD pending datasheet review).

---

## PRIORITY 2 — Polish + reliability

### 6. iOS background mode — CRUCIAL, whole point of the app *(Swift)*
Polling stops when the app is minimised or phone is locked. Display goes stale.

**Swift fix:**
1. Add `bluetooth-central` to `UIBackgroundModes` in Info.plist / Package.swift
2. Pass `CBCentralManagerOptionRestoreIdentifierKey` in `CBCentralManager` init
3. Wrap the poll loop in `ProcessInfo.processInfo.performExpiringActivity(withReason:)`

Must test on real device (simulator doesn't support background BLE).

---

### 7. BLE brightness control *(ESP32 + Swift)*
Brightness is hardcoded to `TFT_BRIGHTNESS_MAX = 200`.

**ESP32** — new BLE write characteristic (`0000ffe5-...`) that accepts one byte and
calls `ledcWrite(TFT_BL, value)`.

**Swift** — `setBrightness(_ value: UInt8)` in `BLEManager`, slider in `SettingsView`,
persisted with `UserDefaults`.

---

### 9. CRC32 integrity on cached files *(ESP32)*
Power loss mid-write silently corrupts a cache file — next load shows garbage pixels.

Append 4-byte CRC32 when saving, verify on load, delete + re-request on mismatch:
```cpp
uint32_t crc = computeCRC32((uint8_t*)imageBuffer, IMAGE_SIZE);
file.write((uint8_t*)&crc, 4);
```

---

## PRIORITY 3 — Nice to have

### 11. More ESP32 transition effects *(ESP32)*
**Status:** ACTIVE (next feature focus)

Current set has 16. Ideas to add (each follows the same `drawXxx(buffer, width, height)`
signature — add enum value, switch case, and name string):
- **Pixel rain** — columns fall from top
- **Spiral** — clockwise reveal from center
- **Clock wipe** — sweeps like a clock hand from 12 o'clock
- **Horizontal blinds** — horizontal strip reveal (complement to existing Venetian V)
- **Shatter** — random 4×4 blocks, denser near center first
- **Cross wipe** — plus-shape expands from center

---

### 12. Let iOS choose the transition *(ESP32 + Swift)*
**Status:** DEPRIORITIZED / DO NOT IMPLEMENT NOW

Prepend a 1-byte transition index to the 4-byte size header (5 bytes total).
ESP32 uses that index instead of random. `0xFF` = keep random (backwards-compatible).
iOS picker is intentionally not in current scope.

---

### 13. App UI redesign *(Swift — do before UIKit migration)*
Redesign the main screen on MacBook before porting to UIKit.

**Tools to consider:** Sketch (Mac-only, great for iOS), Figma (free, browser-based),
or iterate directly in Xcode's SwiftUI live preview. Research and pick your style.

---

### 14. Clear SD cache from app *(ESP32 + Swift)*
New BLE write command (magic `0xCAC4E1EA` via cache characteristic).
ESP32 deletes all `/cache/*.bin` files.
iOS: "Clear cache" button in `SettingsView` with confirmation alert.

---

### 15. Spotify album ID as cache key *(ESP32 + Swift)*!!!!!!
Current key is MD5 of image URL — breaks if Spotify changes CDN.
Album ID is stable and deduplicates all tracks from the same album.

---

### 16. Research: dithering algorithm + ST7789 gamma tuning *(ESP32 + Swift)*
Do this before implementing items 2 and 3.

- **Gamma registers** — write `0xE0` (PVGAMCTRL) and `0xE1` (NVGAMCTRL) after
  `gfx->begin()` using the existing `bus->writeCommand()` pattern. Starting values
  (Adafruit IPS): `0xD0,0x04,0x0D,0x11,0x13,0x2B,0x3F,0x54,0x4C,0x18,0x0D,0x0B,0x1F,0x23`
  (positive) and `0xD0,0x04,0x0C,0x11,0x13,0x2C,0x3F,0x44,0x51,0x2F,0x1F,0x1F,0x20,0x23`
  (negative). Tune on real hardware with a skin-tone/gradient test image.
- **Dithering alternatives** — compare Atkinson, Sierra Lite, Jarvis-Judice-Ninke
  against Floyd-Steinberg on actual hardware for 240×240 photographic RGB565.
- **Color pipeline order** — grade in full precision first, quantize + dither last.
- **iOS CIContext color space** — force `CGColorSpace.sRGB` to prevent extended-sRGB
  values > 1.0 from clipping when packing to RGB565.

### Future Path C (optional, post A+B metrics)
- Keep flash-backend migration as an option only after validating A+B speed/reliability metrics on hardware.
- If SD remains the bottleneck/failure source, run a scoped evaluation (capacity, wear, migration cost) before any backend switch.

---

## FUTURE — once app is fully polished


### 17. get apple dev and implent tool kit
utilize now playing feature and apple music and spotify integration. more embeeded into ecosystem and professional. real app/product not just a college project

### 18. peer 2 peer compare cached songs
someone else has same device, thsoe devices can speak to eachother comparing cache ids (make sure all songs have same cache id)
displays a similiartiy score on both devcies with number and a heart depciting how similar

###  19 Upload custom images and GIFs through the app *(ESP32 + Swift)*
Allow picking any photo or GIF from camera roll and sending it to the display.

**Static images** — add `PHPickerViewController`, pipe through existing
`ImageProcessor.convertToRGB565()`, send via existing BLE transfer. No ESP32 changes.

**Animated GIFs** — decode frames with `ImageIO` (no extra library):
```swift
let source = CGImageSourceCreateWithData(gifData, nil)
let frameCount = CGImageSourceGetCount(source)
// convert each frame to RGB565, send in sequence
```
ESP32 needs a new animation mode: animation header packet (magic + frame count + delay ms),
SD card stores frames as `/anim/00.bin`, `01.bin`, etc., `loop()` cycles with `millis()`.

**Constraints:** 10-frame GIF = ~1.1 MB over BLE (~10 s). Warn before sending.
ESP32 PSRAM (8 MB) fits ~70 frames. Display max ~20–30 fps at 80 MHz SPI.
(downlaod gif first then send over whole thing once complet)
