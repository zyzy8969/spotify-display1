# Swift App — Pending Improvements

## A. Faster BLE image transfer

**Problem:** `BLEManager.swift` has a Write Without Response fast-path already written (line 125 checks `img.properties.contains(.writeWithoutResponse)`), but it never activates. The ESP32 image characteristic is only declared with `PROPERTY_WRITE` (Write With Response), so iOS always falls back to the slow path — each of the 225 chunks waits for a GATT ACK (~15 ms roundtrip × 225 = ~3–7 s total).

**Fix — two parts:**

1. `src/main.cpp`, `setupBLE()` (~line 957): add `PROPERTY_WRITE_NO_RESPONSE` to the image characteristic:
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

2. `BLEManager.swift` line 118: remove the 5 ms post-header sleep (unnecessary once the fast path is active):
   ```swift
   // DELETE this line:
   try await Task.sleep(nanoseconds: 5_000_000)
   ```

**Expected result:** transfer drops from ~3–7 s to ~0.5–1 s.

---

## B. Cancel in-progress transfer when the user skips tracks

**Problem:** If a new song starts while an image is still being sent, the old `sendRGB565` task runs to completion before the new image begins. The display draws the wrong album art until the full old transfer finishes.

**Fix:** In `SpotifyManager`, keep a reference to the active transfer `Task` and cancel it when `currentTrack` changes, then immediately kick off the new track's transfer:
```swift
private var transferTask: Task<Void, Never>?

// When a new track is detected:
transferTask?.cancel()
transferTask = Task { try? await bleManager.processTrack(imageURL: newURL) }
```
Also make `sendRGB565` check `Task.isCancelled` between chunk writes and throw/return early when cancelled.

---

## C. Better colors (Core Image grading to match Python output)

**Problem:** `ImageProcessor.swift` does a plain bilinear resize with no color grading. The Python script applies ImageMagick processing that significantly improves vibrancy and contrast. The iOS image looks washed out by comparison.

**Python settings to replicate:**
- Level: black point = 0.03, white point = 0.90, gamma = 0.89
- Saturation: 110%
- Brightness: 90%
- Contrast: +19

**Fix:** Apply equivalent Core Image filters in `ImageProcessor.swift` after resizing, before RGB565 conversion:
```swift
// Levels (approximate with CIColorControls + CIExposureAdjust)
let contrastFilter = CIFilter.colorControls()
contrastFilter.saturation = 1.10
contrastFilter.brightness = -0.05
contrastFilter.contrast = 1.15

// Gamma correction
let gammaFilter = CIFilter.gammaAdjust()
gammaFilter.power = 1.0 / 0.89  // ~1.12

// White/black clipping (approximate level adjustment)
let clampFilter = CIFilter.colorClamp()
clampFilter.minComponents = CIVector(x: 0.03, y: 0.03, z: 0.03, w: 0)
clampFilter.maxComponents = CIVector(x: 0.90, y: 0.90, z: 0.90, w: 1)
```
Chain these before the final `CIContext.render` step.

---

## D. App background not fully white on dark-mode devices

**Problem:** `ContentView`'s `NavigationStack` is missing `.background(Color.white)` and `.preferredColorScheme(.light)`. On iPhones set to dark mode, the system fills safe-area gaps and navigation bar regions with the dark system background color, leaving non-white areas around the edges of the app.

**Note:** `SettingsView` already fixes this correctly — it has both modifiers on its `NavigationStack`.

**Fix:** Add two modifiers to the `NavigationStack` in `ContentView.swift`:
```swift
NavigationStack {
    // ... existing content unchanged ...
}
.background(Color.white)          // add this
.preferredColorScheme(.light)     // add this
```
