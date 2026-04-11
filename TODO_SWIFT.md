# Polishing Roadmap — ESP32 + Swift App
> Goal: fully polished experience before migrating UI to UIKit.
> Items ordered by impact.

---

## PRIORITY 1 — Core experience

### 1. Faster BLE image transfer *(ESP32 + Swift)*
**Status: DONE** — `PROPERTY_WRITE_NR` added to firmware, confirmed faster on device.
Remaining Swift half: remove the 5 ms post-header sleep in `BLEManager.swift` line 118:
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
When the user skips, the old transfer finishes before the new one starts.

**Swift** — `SpotifyManager.swift`: hold a reference to the active `Task` and cancel on
new track detection:
```swift
private var transferTask: Task<Void, Never>?
transferTask?.cancel()
transferTask = Task { try? await bleManager.processTrack(imageURL: newURL) }
```
Also check `Task.isCancelled` between writes in `BLEManager.sendRGB565()`.

---

### 5. Fix app background not fully white *(Swift)*
`ContentView`'s `NavigationStack` is missing `.background(Color.white)` and
`.preferredColorScheme(.light)` — on dark-mode devices safe-area gaps turn dark.
`SettingsView` already has both; apply the same to `ContentView`.

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
The count shows but only after tapping "Cache count" manually. It should:
- Refresh automatically on connect (verify `onCharacteristicsReady()` updates the
  `@Published var sdCacheEntryCount` and `ContentView` is observing it)
- Always be visible when connected ("X songs cached")
- Refresh after each successful transfer in `SpotifyManager`

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
`lastError` in `SpotifyManager` is set on failure but never cleared on success.

```swift
self.lastError = nil  // add at top of successful poll path in pollOnce()
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

**Design direction:**
- Full-bleed album art as background (blurred + darkened)
- Album art large and centered
- Track name + artist in a frosted glass card at the bottom
- BLE status as a small dot only
- Transfer progress as a thin bar at the very bottom edge
- Minimal chrome — the art dominates

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

### 17. Upload custom images and GIFs through the app *(ESP32 + Swift)*
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
