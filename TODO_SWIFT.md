# Polishing Roadmap — ESP32 + Swift App
> Goal: fully polished experience before migrating UI to UIKit.
> Items ordered by impact.

---

## Swift quick wins (no `main.cpp` update required)

**Status:** Implemented in the Swift package (BLEManager, ContentView, SpotifyManager) — no `main.cpp` changes in that commit.

These work with **your current firmware** (already has `PROPERTY_WRITE_NR`, stats magic `0xC0FFEEE1`, `CACHE_COUNT:` on the message characteristic). Pull Swift on any machine; flash ESP32 only when you tackle the **ESP32 / `main.cpp` — laptop backlog** section below.

**Do on laptop / in Xcode (Swift only):**

1. **`BLEManager.swift` — faster BLE** — Delete the 5 ms sleep after the 4-byte image header write (`sendRGB565`, the line `try await Task.sleep(nanoseconds: 5_000_000)`). Header is already `.withResponse`; firmware does not need a change for this.

2. **`ContentView.swift` — light chrome** — On the root `NavigationStack` (same level as `.background(Color.white…)`), add `.preferredColorScheme(.light)` so semantic colors match `SettingsView` on dark-mode phones.

3. **`SpotifyManager.swift` — clear stale errors** — At the start of the successful `pollOnce` path (right after `let state = try await fetchCurrentlyPlayingWithRefresh()`), set `lastError = nil`. Optionally also set `lastError = nil` when a display transfer completes successfully in the `artSendTask` completion path.

4. **`BLEManager.swift` + `ContentView.swift` — cache total always on when connected**  
   - Add `@Published private(set) var sdCacheCountLoading = false` (or equivalent). On `didConnect`: `sdCacheEntryCount = nil`, `sdCacheCountLoading = true`. On `didDisconnect`: clear count, `sdCacheCountLoading = false`.  
   - In `onCharacteristicsReady`, after `waitForReady()`, use `defer { sdCacheCountLoading = false }` and `try await refreshSDCacheCount()` (not `try?`) so failures end loading state.  
   - **`ConnectionStatusView`:** when `isConnected`, always show a third line: loading text (e.g. “Total cached on display: …”) while `sdCacheCountLoading && sdCacheEntryCount == nil`, else `Total cached on display: \(n)` when count is known (including **0**), else “—” if load failed.  
   - After a **successful** full image send in `sendRGB565` (after `SUCCESS`), call `try? await refreshSDCacheCount()` so the total updates when a new file lands on SD.  
   - Remove the manual **“Cache count”** button once the above is reliable (or keep it only as a manual retry).

---

## ESP32 / `main.cpp` — laptop backlog (git + flash here)

Do these on the machine where your **known-good** `src/main.cpp` lives; push before/after each logical chunk. Update [`docs/BLE_PROTOCOL.md`](docs/BLE_PROTOCOL.md) whenever GATT or file formats change.

| Roadmap item | File / area | What to change (high level) |
|--------------|---------------|------------------------------|
| **2** Move dither to iOS | `loop()` ~transfer complete | Remove `applyFloydSteinbergDithering` and the full-screen `drawImageLineByLine` redraw after receive; save **pre-dithered RGB565** from iOS straight to SD (or save buffer as received once iOS sends dithered data). Coordinate with Swift `ImageProcessor` port of `applyFloydSteinbergDithering`. |
| **7** BLE brightness | GATT setup + new UUID `0000ffe5-…` | One-byte write → `ledcWrite(TFT_BL, value)` (replace fixed `TFT_BRIGHTNESS_MAX`). Swift: `BLEManager.setBrightness`, Settings slider, `UserDefaults`. |
| **9** CRC32 on cache | `saveToCache` / cache load path | After `IMAGE_SIZE` bytes, append 4-byte CRC32; on load recompute and delete + miss if mismatch. |
| **11** More transitions | Transition switch / helpers | Add `drawXxx` + enum + name string (pixel rain, spiral, etc.). |
| **12** iOS-picked transition | Image header / BLE parser | First byte transition index + existing 4-byte LE size (5-byte header); `0xFF` = random. Parse in firmware image receive state machine. |
| **14** Clear SD from app | Cache characteristic handler | Magic `0xCAC4E1EA` → delete `/cache/*.bin`, reply on message char. |
| **15** Album ID cache key | Cache key derivation | Replace or dual MD5(image URL) with stable album id from app; align 16-byte key layout with iOS. |
| **16** Gamma + tuning | After `gfx->begin()` | ST7789 `0xE0` / `0xE1` gamma register blocks via `bus->writeCommand()`; tune on hardware. Optional: compare dither variants in firmware **or** only on iOS once dither moves off device. |
| **19** GIF animation | New BLE mode + `loop()` | New packet magic; multi-frame `/anim/*.bin`; cycle with `millis()` and frame delay. |

**Already in your `main.cpp` (no laptop action for Swift-only quick wins):** `PROPERTY_WRITE_NR` on image char, cache check, progressive line draw, FS dither path, stats request handling.

---

## PRIORITY 1 — Core experience

### 1. Faster BLE image transfer *(ESP32 + Swift)*
**Firmware: DONE** — `PROPERTY_WRITE_NR` on device; no laptop change needed for Swift quick wins above.
**Swift:** remove the 5 ms post-header sleep in `BLEManager.swift` (`sendRGB565`):
```swift
// DELETE: try await Task.sleep(nanoseconds: 5_000_000)
```

---

### 2. Move Floyd-Steinberg dithering to iOS *(ESP32 + Swift)*
Currently: ESP32 draws image line-by-line → display freezes ~300–500 ms while dithering
runs → entire screen redrawn. Two full draws per song.

**Swift** — port `applyFloydSteinbergDithering()` from `main.cpp` into `ImageProcessor.swift`,
apply to the `[UInt16]` pixel buffer before packing to `Data`.

**ESP32** — remove `applyFloydSteinbergDithering()` call and the `drawImageLineByLine`
redraw that follows it (~line 1412 in `loop()`). Just save to cache immediately.

---

### 3. Fix color grading — match Python output *(Swift)*
`ImageProcessor.swift` skips the level-clamp step the Python script does, so iOS images
look washed out by comparison.

**Swift** — add `CIColorClamp` before existing Core Image filters in `ImageProcessor.swift`:
```swift
let clamp = CIFilter.colorClamp()
clamp.minComponents = CIVector(x: 0.03, y: 0.03, z: 0.03, w: 0)
clamp.maxComponents = CIVector(x: 0.90, y: 0.90, z: 0.90, w: 1)
// then existing gamma (0.89), saturation (110%), contrast (+19)
```

---

### 4. Cancel transfer immediately on track skip *(Swift)*
**Status: largely DONE in repo** — `SpotifyManager` uses `artSendTask` / `artInFlightTrackId` and cancels on track change; `BLEManager` uses `transferEpoch` / `cancelOngoingTransfer()` / `ensureTransferEpoch()` instead of the snippet below. Optional: call `Task.checkCancellation()` in the send loop (epoch checks already enforce abort).

Legacy sketch (superseded):
```swift
private var transferTask: Task<Void, Never>?
transferTask?.cancel()
transferTask = Task { try? await bleManager.processTrack(imageURL: newURL) }
```

---

### 5. Fix app background not fully white *(Swift)*
`AppDelegate` already forces light `UIWindow` / white roots. **Remaining:** add `.preferredColorScheme(.light)` on `ContentView`’s `NavigationStack` (see **Swift quick wins** at top). Background white is largely in place.

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

### 8. Fix cache count display *(Swift)*
See **Swift quick wins** at top (always show total when connected, loading vs `0…N`, refresh after send, drop manual button). `onCharacteristicsReady()` already calls `refreshSDCacheCount()`; no `main.cpp` change required.

---

### 9. CRC32 integrity on cached files *(ESP32)*
Power loss mid-write silently corrupts a cache file — next load shows garbage pixels.

Append 4-byte CRC32 when saving, verify on load, delete + re-request on mismatch:
```cpp
uint32_t crc = computeCRC32((uint8_t*)imageBuffer, IMAGE_SIZE);
file.write((uint8_t*)&crc, 4);
```

---

### 10. Fix stale error message *(Swift)*
`lastError` is set on failure but should clear on success — see **Swift quick wins** at top (`lastError = nil` after successful `fetchCurrentlyPlayingWithRefresh()` in `pollOnce`, and optionally after successful BLE send).

```swift
self.lastError = nil  // after successful fetch in pollOnce()
```

---

## PRIORITY 3 — Nice to have

### 11. More ESP32 transition effects *(ESP32)*
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
Prepend a 1-byte transition index to the 4-byte size header (5 bytes total).
ESP32 uses that index instead of random. `0xFF` = keep random (backwards-compatible).
iOS adds a picker in Settings.

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

### 15. Spotify album ID as cache key *(ESP32 + Swift)*
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

