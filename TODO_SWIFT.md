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
- Fix intermittent skip-render artifact: after skip/reconnect, previous image may appear briefly before correct next track renders. Root cause TBD (cache status vs transfer/render sequencing).

### End-of-session issue capture (2026-04-15)
- App: cover art can resize during download and then return to normal.
- App: UI still does not fill the entire screen consistently.
- Intermittent skip-render artifact: previous image can appear briefly before the correct next track renders. Root cause TBD (cache status vs transfer/render sequencing).

## Audit backlog (2026-11-18) — from `docs/AGENT_REPORT.md`

Full reasoning, line references and citations live in [`docs/AGENT_REPORT.md`](docs/AGENT_REPORT.md).
Severity order. `[fw]` firmware, `[app]` iOS, `[both]` crosses the boundary.

### Done, awaiting hardware verification
- [x] **Brightness never worked** `[both]` — `ledcWrite()` was passed the GPIO instead of the LEDC
  channel, so every BLE brightness write hit a nonexistent channel. Fixed with a named
  `TFT_BL_PWM_CHANNEL`. **Also needed an app-side fix**: `UserDefaults.integer(forKey:)` returns 0
  when unset, so a fresh install pushed brightness 0 and would have blacked out the screen once the
  firmware started obeying it. Branch `fix/brightness-ledc-channel`. **Brightness confirmed working
  on hardware 2026-11-19.** Needed `platform = espressif32@6.5.0` (core 2.0.14): core 3.x removed
  `ledcSetup`/`ledcAttachPin`.
- [x] **Skip matched the old song's cache reply to the new song** `[app]` — the skip-render
  artifact. Skipping cancelled the app's wait but not the board's reply, and replies carry no song
  id, so A's late "hit" was taken as B's answer: "cache hit 0.1s" for a song never drawn or sent,
  and "draws one line and stops". Fix: `BLEManager` tracks replies the board still owes
  (`cacheReplyOwed`, `imageAckOwed`) and `processTrack` waits them out (max 8 s) before asking about
  the next song. App-only, no protocol change. Cleaner alternative still open: echo the cache key in
  every reply (protocol change, needs sign-off).
- [x] **Frame buffer overwritten mid-draw** `[fw]` — `loop()` handled a cache check before finishing
  a just-completed transfer, so a hit could load over `imageBuffer` before it was saved, and the save
  used `currentCacheKey` (already the next song's). Fix: the cache check now waits a loop iteration
  while `imageTransferComplete` is pending, and frames are saved under `transferCacheKey`, snapshotted
  at the image header. Note the app fix above already stops our app from triggering this.
- [x] **`awaitWriteWindow` lost wakeup** `[app]` — now re-checks every 100 ms, never overwrites a
  parked waiter, and exits when the transfer epoch changes (cancel also wakes it).
- [x] **Stale timeout kills healthy transfers** `[app]` — the SUCCESS timeout task now has a
  generation guard, and an exiting old task no longer nils out the newer task's handle.
- [x] **Token refresh race** `[app]` — refreshes are single-flight (`tokenRefreshTask`), so
  concurrent callers share one request and one rotated token.
- [x] **Random pixels at boot** `[fw]` — panel RAM was visible with the backlight on during SD init;
  `setup()` now clears to black right after `gfx->begin()`.

All six above: firmware compiles locally; app compiles only in the cloud build. **Not yet verified on
hardware** — see the skip stress test in `docs/VALIDATION_CHECKLIST.md`.

### Image quality (do as ONE pass, with before/after photos — not with the brightness flash)
- [ ] **Quantiser truncates instead of rounding** `[app]` — `Int(UInt16(oldR) >> 3)` biases error
  to about +3 instead of straddling zero, doubling dither noise and (because Atkinson discards 25%
  of error) throwing away brightness. Two-line fix, highest value in the image path.
- [ ] **Grading clamp is cancelled by its own contrast filter** `[app]` — move `CIColorClamp` to
  the end of `applyGrading`.
- [ ] **Double gamma boost** `[both]` — the app grade and the panel gamma registers both push for
  "punch", and the firmware curve deviates from `resources/` reference. Aggressive panel gamma also
  breaks dithering, which relies on near-linear response between adjacent levels. Revert the panel
  to reference, keep the look on the phone.
- [ ] **Prefer largest album art, not 300×300** `[app]` — `preferredArtURLs` sorts exact 300×300
  first. Download size does not affect BLE time; a 640→240 downscale averages away Spotify's JPEG
  artifacts, which otherwise get locked in by dithering. Update `VALIDATION_CHECKLIST.md` too.
- [ ] **Bump `CACHE_KEY_VERSION`** `[fw]` whenever any of the above lands — the cache is keyed on
  album, not pipeline, so old entries keep the old look and you end up comparing two pipelines.
- [ ] No serpentine scan `[app]` — error always diffuses one direction; faint worming in gradients.

### UI / accessibility (see report §10, reviewed against Apple HIG)
Fixed in code on `feat/themes-ui` (three themes from the Design canvas). **Not compiled locally, not
yet verified on a device** — see `docs/VALIDATION_CHECKLIST.md` › "iOS UI (themes)".
- [x] **Connection state is colour-only and invisible to VoiceOver** `[app]` — dots are now filled
  (connected) vs hollow ring (not connected) and each has an `.accessibilityLabel`.
- [x] **The live strip inherits the same gap** — cached vs fresh is a filled dot vs hollow ring at
  the strip's start as well as colour; the strip has an accessibility label and value.
- [x] **Appearance picker** — replaced by a *theme* picker (Crayon / Quiet / Serif); each theme sets
  its own colour scheme. There is no separate light/dark/system switch.
- [x] Fixed 11 pt debug type ignores Dynamic Type `[app]` — now `.caption2` monospaced; every other
  text uses `Font.custom(_:size:relativeTo:)` or UIFontMetrics scaling.
- [x] Six accent colours with no system `[app]` — one colour per meaning per theme (Spotify, display
  / cached, fresh send), all in `Theme.swift` with contrast figures.
- [x] Sign-in screen gives no reason for signing in `[app]` — signed-out screen explains it and says
  the password stays with Spotify.
- [x] Album art resizes mid-download `[app]` — art side depends only on the safe-area size; transient
  status no longer sits above the art.
- [ ] **Mirror the board's draw state in the app preview** `[app]` — *fresh sends done*: the preview
  masks the new cover to `transferProgress` (= rows drawn) with the previous cover below the scan line.
  *Cache hits still open*: they need the app to stop sending `0xFF` (random) in the 5-byte header and
  pick the transition itself — the protocol already carries a transition index, it is just unused
  (`BLEManager.sendRGB565`) — then run the same animation locally. That is a `BLEManager` behaviour
  change, so it was left for a separate, approved step.
- [x] Blanket `.ignoresSafeArea()` pushes the bottom bar under the home indicator `[app]` — only the
  background ignores safe areas now.
- [ ] Increase Contrast has no dedicated palette `[app]` — every theme already passes AA without it;
  a higher-contrast variant per theme is a possible follow-up.

### Auth hardening (report §11 — PKCE itself is correctly built)
- [ ] `restoreSession()` reports "Session expired" for network failures `[app]`.
- [ ] Spotify's `error_description` is discarded `[app]`.
- [ ] `KeychainHelper.save` ignores `SecItemAdd` status — silent logout one launch later `[app]`.
- [ ] No `state` parameter `[app]` — low risk under `ASWebAuthenticationSession`, add anyway.

### Hygiene / process
- [ ] **Pin `platform = espressif32`** — unpinned, and core 3.x inverts the meaning of the
  brightness fix. Highest-value hygiene item.
- [ ] Remove `AgentDebugLog` — dead Cursor instrumentation shipping in the app `[app]`.
- [ ] CI: fail on Swift warnings; regenerate the Xcode project to catch a forgotten
  `gen_xcodeproj.py`. Both free, repo is public so Actions minutes are free.
- [ ] `sdkconfig.defaults` is inert under `framework = arduino` — delete or mark as such `[fw]`.
- [ ] Docs say a 32 s transfer timeout; code says 8 s.
- [ ] `src/main.cpp:45` claims GPIO1 as LCD bus MISO; the LCD has no MISO and GPIO1 is a free
  header pin. Pass `GFX_NOT_DEFINED` `[fw]`.
- [ ] Perf, no visual change `[app]`: `CIContext.render(toBitmap:)` removes a whole redundant
  rasterisation; `vDSP_vfltu8` replaces the UInt8→Float loop.
- [ ] Move `SpotifyDisplay_UI_Spec.md` into `docs/` so it is versioned with the code.

### Captured 2026-11-18 from the UI mockup session (features, not fixes)
Mockups for these live on the design canvas. None are started.

- [ ] **Set a still picture on the device** `[app]` — pick from the camera roll and display it
  instead of album art. Easiest of the lot: `PHPickerViewController` → existing
  `ImageProcessor.convertToRGB565()` → existing BLE image path. **No firmware change, no API, no
  licensing question.** Needs a "pinned" mode so the next track does not overwrite it — app-side
  only, since the app decides what to send. Ship this before the GIF work.
- [ ] **GIF search from an API** `[both]` — mocked up. Extends roadmap item 19.
  **Use GIPHY: Tenor is out.** Tenor's own quickstart carries the notice "As of Jan 2026, we are no
  longer accepting new API clients", so a new key is not obtainable
  (<https://developers.google.com/tenor/guides/quickstart>).
  GIPHY specifics, from <https://developers.giphy.com/docs/api/>:
  - API key required on every call. Beta keys are rate limited to **100 calls/hour**, `limit` max
    50 per search. Production needs an application and GIPHY "will reach out to discuss pricing" —
    100/hour is plenty for personal use. Separate keys per platform. Key goes in Info.plist like
    `SpotifyClientID`, never committed.
  - **"Powered By GIPHY" attribution is mandatory** and must be "conspicuously" displayed where the
    API is used. It is in the mockup footer. Approved marks: `giphy-attribution-marks.zip`.
  - Request the **small renditions** — `downsized_small` (max 200 kB) or `fixed_width_small`. We
    only need 240×240, so never pull `original`.
  - **Decided 2026-11-18: GIFs are never written to the SD card — only music art is cached.**
    This sidesteps GIPHY's "do not cache or store copies of GIPHY's media assets" clause entirely,
    and it simplifies the firmware. Frames live in **PSRAM only** and are lost on power cycle.
  - Firmware side, revised by that decision: animation mode with a new packet magic, frames held
    in PSRAM (no `/anim/` directory, no SD writes), `loop()` cycling on `millis()`. **Playback is
    actually faster this way** — a PSRAM read per frame beats re-reading 115 KB off SD, which is
    what would have capped the frame rate. Budget: 115,200 bytes/frame against 8 MB PSRAM, less
    the existing image buffer and BLE stack — roughly 30–40 frames is the realistic ceiling, so
    the ~12-frame trim (~1.4 MB, ~14 s over BLE) sits comfortably inside it.
  - Consequence to show in the UI (already in the mockup): a GIF is a temporary mode. Unplug the
    keychain and it is gone, and it falls back to album art. Re-sending costs another ~14 s.
  - **The still picture is the exception**: it is the user's own photo with no third-party terms,
    so that one *can* be written to SD and survive a reboot if a persistent "wallpaper" is wanted.
- [ ] **Live log view in the app** `[both]` — mocked up, **but needs a protocol change and your
  OK**. The firmware prints these lines over USB serial only; forwarding them to the phone means a
  new notify characteristic (log level + UTF-8 line), rate limiting so logging does not starve the
  image transfer, and a firmware-side ring buffer. Not started.
- [ ] **Theme choice** `[app]` — three directions mocked: Crayon (Comic Sans, white, bright),
  Quiet (dark, small colour accents), Serif (paper, Times New Roman). Undecided.
  Note: **iOS has no Comic Sans** — the stack falls back to Chalkboard SE. Bundling Comic Neue
  would be needed for a consistent look.
- [ ] **Peer-to-peer similarity score** `[both]` — extends roadmap item 18 with the agreed visual:
  two devices compare cached track IDs and each shows an **8-bit heart filled in proportion to the
  match percentage**, bottom-up, with the caption "music similarity score" on the device screen.
  240×240 device mockup is on the canvas. Prerequisite from the protocol doc: cache keys must be
  **track-ID-based and identical across devices** — today the key is MD5 of `album:<id>`, which is
  stable between devices, so this is closer than it looks. Still needs a device-to-device BLE role
  (both units currently act only as peripherals).

### Physical model (captured 2026-11-18 — requirements only, nothing designed)
- Attachment: a **clip** in the spirit of the square iPod nano, possibly **plus a magnet**; or at
  minimum a **slit in the plastic** for a keychain loop.
- Constraint: the keychain attachment must hold the unit **flat and square to the plane (180°)** —
  it should not hang skewed.
- These are enclosure requirements to carry into the eventual CAD work. Per the standing
  instruction, no enclosure or PCB design has been started.

### Unused hardware already on the board (not bugs — future leverage)
`VBAT_ADC` GPIO6 (the BLE Battery Service in `docs/BLE_PROTOCOL.md` says "requires hardware" — it
is already wired), WS2812B RGB LED GPIO15, QMI8658 IMU GPIO47/48 + INT 45/46, `RST_Control` GPIO19.

---

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
