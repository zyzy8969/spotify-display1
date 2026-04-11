# Polishing Roadmap — ESP32 + Swift App
> Goal: fully polished experience before migrating UI to Apple ToolKit (UIKit).
> Items ordered by impact. Fix ESP32 + Swift together where changes are paired.

---

## PRIORITY 1 — Core experience (do these first)

### 1. Faster BLE image transfer *(ESP32 + Swift)*
**Status:** Not done  
The iOS fast-path (`writeWithoutResponse`) is already written in `BLEManager.swift` line 125
but never activates because the ESP32 characteristic doesn't advertise the property.

**ESP32 fix** — `src/main.cpp`, `setupBLE()` ~line 957:
```cpp
// BEFORE
pImageChar = pService->createCharacteristic(
    IMAGE_CHAR_UUID,
    BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_NOTIFY
);
// AFTER
pImageChar = pService->createCharacteristic(
    IMAGE_CHAR_UUID,
    BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NO_RESPONSE | BLECharacteristic::PROPERTY_NOTIFY
);
```
**Swift fix** — `BLEManager.swift` line 118: delete the 5 ms post-header sleep:
```swift
// DELETE this line:
try await Task.sleep(nanoseconds: 5_000_000)
```
Expected result: ~3–7 s → ~0.5–1 s per transfer.

---

### 2. Move Floyd-Steinberg dithering to iOS *(ESP32 + Swift)*
**Status:** Not done — biggest visible glitch to fix  
Currently: ESP32 draws image line-by-line → **display freezes** ~300–500 ms while
dithering runs → entire image redrawn from scratch. Two full draws per song.  
Fix: do dithering in `ImageProcessor.swift` before sending. ESP32 draws once, saves,
done. No freeze, no double-draw.

**Swift** — add Floyd-Steinberg to `ImageProcessor.swift` after RGB565 conversion.
The algorithm is the same as the C++ in `applyFloydSteinbergDithering()` in `main.cpp`
(direct port). Apply to the `[UInt16]` pixel array before packing to `Data`.

**ESP32** — once iOS sends pre-dithered data, remove the dithering call in `loop()`
(the `applyFloydSteinbergDithering` call ~line 1412) and remove the full redraw that
follows it (`drawImageLineByLine`). Just save to cache immediately after transfer.

---

### 3. Fix color grading — iOS output must match Python *(Swift)*
**Status:** Not done  
`ImageProcessor.swift` applies gamma, saturation, contrast via Core Image but skips
the level clamp step the Python script does. Result: iOS-sent images look washed out
vs Python-sent ones.

Python settings to replicate exactly:
- `level(black=0.03, white=0.90, gamma=0.89)` — hard clamp + rescale
- `saturation=110%`, `brightness=90%`, `contrast=+19`

**Swift fix** — in `ImageProcessor.swift`, add `CIColorClamp` before existing filters:
```swift
// Step 1: level clamp (black/white point)
let clamp = CIFilter.colorClamp()
clamp.inputImage = ciImage
clamp.minComponents = CIVector(x: 0.03, y: 0.03, z: 0.03, w: 0)
clamp.maxComponents = CIVector(x: 0.90, y: 0.90, z: 0.90, w: 1)

// Then existing CIColorControls for sat/brightness/contrast
// gamma stays as CIGammaAdjust(power: 1/0.89)
```

---

### 4. Cancel transfer immediately on track skip *(Swift)*
**Status:** Not done  
When the user skips, the active `sendRGB565` task runs to completion before the new
image starts. `transferEpoch` exists in the code but is only checked every ~1 ms delay
in the write loop. A skip triggers only on the *next* 1 s Spotify poll.

**Swift fix** — `SpotifyManager.swift`: store the active transfer `Task` and cancel it
the moment a new track is detected, before waiting for the next poll:
```swift
private var transferTask: Task<Void, Never>?

// On new track detected:
transferTask?.cancel()
transferTask = Task { try? await bleManager.processTrack(imageURL: newURL) }
```
Also check `Task.isCancelled` between chunk writes in `BLEManager.sendRGB565()` and
return early if cancelled.

---

### 5. Fix app background not fully white *(Swift)*
**Status:** Not done  
`ContentView`'s `NavigationStack` is missing `.background(Color.white)` and
`.preferredColorScheme(.light)`. On dark-mode devices the safe-area gaps and nav bar
turn dark. `SettingsView` already has both modifiers — apply the same to `ContentView`:
```swift
NavigationStack { ... }
    .background(Color.white)
    .preferredColorScheme(.light)
```

---

## PRIORITY 2 — Polish + reliability

### 6. Random transitions for new transfers, not just cache hits *(ESP32)*
**Status:** Not done  
Cache hits use `drawImageWithRandomTransition()` (nice wipe/zoom effects).
New image transfers use a plain top-to-bottom line draw (`drawImageLineByLine`).
Once dithering moves to iOS (item 2), the transfer-complete path just needs to call
`drawImageWithRandomTransition(imageBuffer, DISPLAY_WIDTH, DISPLAY_HEIGHT)` instead
of `drawImageLineByLine`. One line change.

---

### 7. BLE brightness control characteristic *(ESP32 + Swift)*
**Status:** Not done  
Brightness is hardcoded to `TFT_BRIGHTNESS_MAX = 200` in firmware.

**ESP32** — add a new BLE write characteristic (e.g. `0000ffe5-...`) that accepts
a single byte (0–255) and calls `ledcWrite(TFT_BL, value)`.

**Swift** — add a `setBrightness(_ value: UInt8)` method to `BLEManager` and expose
a slider in `SettingsView`. Persist last value with `UserDefaults`.

---

### 8. SD card cache eviction *(ESP32)*
**Status:** Not done  
No eviction policy — cache grows forever. After ~200–300 songs the SD card fills and
`saveToCache` fails silently.

**ESP32 fix** — in `saveToCache()`, after saving check total file count in `/cache`.
If count > 200 (configurable), delete the oldest file (FAT32 creation time or
alphabetically first, since filenames are MD5 hex):
```cpp
uint32_t n = countCacheBinFiles();
if (n > MAX_CACHE_FILES) {  // define MAX_CACHE_FILES 200
    // open /cache, openNextFile(), delete the first one found
}
```

---

### 9. CRC32 integrity check on cached files *(ESP32)*
**Status:** Not done  
If power dies mid-write the cache file is silently corrupted. Next load displays
garbage pixels with no error.

**ESP32 fix** — append a 4-byte CRC32 when saving:
```cpp
uint32_t crc = computeCRC32((uint8_t*)imageBuffer, IMAGE_SIZE);
file.write((uint8_t*)&crc, 4);
```
On load, recompute and compare. If mismatch, delete the file and return `false`
so the caller falls through to a fresh BLE transfer.

---

### 10. Fix stale error message in iOS *(Swift)*
**Status:** Not done  
`lastError` in `SpotifyManager` is set on failures but never cleared on success.
A token error at 9 am stays on screen all day even after auto-refresh succeeds.

**Swift fix** — in `pollOnce()`, clear `lastError` at the top of a successful response:
```swift
self.lastError = nil  // add at start of successful poll path
```

---

### 11. iOS background mode — keep polling when app is minimised *(Swift)*
**Status:** Not done — most impactful daily-use improvement  
Currently polling stops the moment you lock your phone or switch apps.

**Swift fix:**
1. Add `bluetooth-central` to `UIBackgroundModes` in app entitlements/Info.plist
2. In `CBCentralManager` init, pass `CBCentralManagerOptionRestoreIdentifierKey`
   for state restoration
3. Request `background` processing time in `SpotifyManager.startMonitoring()` using
   `BGAppRefreshTask` or `ProcessInfo.performExpiringActivity`

This requires a real device (simulator doesn't support background BLE) and the
entitlement must be declared before App Store submission.

---

## PRIORITY 3 — Nice to have

### 12. Let iOS choose the transition *(ESP32 + Swift)*
Prepend a 1-byte transition index to the 4-byte size header (total 5 bytes).
ESP32 reads it and uses that transition instead of random. iOS adds a picker in
Settings. Value `0xFF` = keep random (default, backwards-compatible).

### 13. In-app cache count display *(Swift)*
Already have `sdCacheEntryCount` published from `BLEManager` and
`refreshSDCacheCount()`. Just surface it more prominently in `ContentView` — e.g.
"83 songs cached" under the connection dot.

### 14. Clear SD cache from app *(ESP32 + Swift)*
New BLE write command (e.g. magic `0xCAC4E1EA` via cache characteristic).
ESP32 iterates `/cache` and deletes all `.bin` files.
iOS adds a "Clear cache" button in `SettingsView` with a confirmation alert.

### 15. Research: best dithering algorithm + color pipeline for ST7789 display *(ESP32 + Swift)*
**Research task — do before implementing item 2 (dithering) and item 3 (color grading)**

The ST7789VW panel on this board is RGB565 (65,536 colors) with IPS backlighting.
Current approach uses Floyd-Steinberg dithering. Need to research whether there are
better options for this specific display and album art content (photographic images,
vibrant saturated colors).

**Questions to answer before coding:**
1. **ST7789 panel gamma registers** — the firmware currently leaves the ST7789VW
   gamma registers (0xE0 PVGAMCTRL, 0xE1 NVGAMCTRL) at power-on defaults after
   calling `gfx->begin()`. Writing tuned values here can improve color accuracy and
   richness before any software dithering is applied. Research and implement the
   correct 14-byte positive and negative gamma curves for the Waveshare ESP32-S3
   1.3" IPS panel (ST7789VW chip). The gamma write uses the same `bus->beginWrite()` /
   `bus->writeCommand()` / `bus->write()` / `bus->endWrite()` pattern already present
   for the MADCTL register in `setup()`. Good starting point: Adafruit_ST7789 IPS values
   (PVGAMCTRL: 0xD0,0x04,0x0D,0x11,0x13,0x2B,0x3F,0x54,0x4C,0x18,0x0D,0x0B,0x1F,0x23;
   NVGAMCTRL: 0xD0,0x04,0x0C,0x11,0x13,0x2C,0x3F,0x44,0x51,0x2F,0x1F,0x1F,0x20,0x23).
   Tune on real hardware by displaying a test image with skin tones and gradients.

2. **Dithering algorithm** — Floyd-Steinberg is the current choice. Alternatives:
   - Atkinson (less aggressive error diffusion, often looks crisper on small screens)
   - Jarvis-Judice-Ninke (wider diffusion kernel, smoother gradients)
   - Blue-noise / ordered dithering (no direction artifacts, good for photos)
   - Sierra (compromise between FS and JJN)
   Research which algorithm produces the least banding on 240×240 RGB565 for
   photographic content. Test all on actual hardware if possible.

2. **Color pipeline order matters** — does dithering happen before or after color
   grading? Grading then dithering is standard (grade in full precision, quantize last).
   Confirm this is what both iOS and ESP32 should do.

3. **RGB565 gamma** — ST7789 has its own internal gamma curve (GAMMA SET register 0xE0/0xE1).
   The current firmware writes `MADCTL = 0x00` (RGB mode) but doesn't touch the gamma
   registers — they're left at power-on defaults. Research whether tuning the panel gamma
   via the GAMMA SET commands would improve perceived color accuracy without needing
   software dithering at all, or whether both are needed.

4. **Saturation on RGB565** — blues and greens are slightly overrepresented in RGB565
   (6-bit green vs 5-bit red/blue). Research whether a per-channel weighting during
   quantization (e.g. perceptual weighting) reduces the green tinge some RGB565 displays show.

5. **iOS Core Image accuracy** — `CIContext` renders in extended sRGB by default on
   modern iPhones. Research whether this affects the RGB565 output (extended color values
   > 1.0 getting clipped) and if `CGColorSpace.sRGB` should be forced explicitly.

**Deliverable:** Update items 2 and 3 in this file with the chosen algorithms and
any panel gamma register values to write in firmware.

---

### 16. Spotify track ID as cache key instead of image URL hash *(ESP32 + Swift)*
Multiple tracks sharing an album have the same art — they'd share one cache entry.
But if Spotify changes the CDN URL, the existing cache entry is orphaned.
Using track ID avoids CDN dependency but loses the album-level dedup.
Consider using album ID as key instead — same art, stable key.
