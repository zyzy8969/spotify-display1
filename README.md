# Spotify Display

An **ESP32-S3** pulls **Spotify album art** from an **iOS app** over **BLE** and renders it on a **240×240 ST7789 LCD**. Images are color-graded, dithered to RGB565, cached to SD card, and revealed with one of 16 animated transitions.

---

## What works right now

- iOS app polls Spotify every ~1 s, detects track changes, downloads album art
- Art is processed on-device (color grade + Floyd-Steinberg dither — move to iOS is on the roadmap)
- BLE transfer uses Write Without Response (fast path) — ~0.5–1 s per image
- ESP32 checks SD cache first (MD5 of image URL); cached songs show a random transition, new songs draw top-to-bottom progressively so you can tell a new track is arriving
- SD card holds up to ~32 GB of cached images
- 16 transition effects implemented on ESP32

## Recent changes (Apr 2026)

- Added `PROPERTY_WRITE_NR` to image BLE characteristic → unlocks iOS fast path (confirmed faster on device)
- Extracted `decodeLE32()` helper (3 call sites)
- Extracted `drawBlockRows()` helper (removes duplication)
- Fixed `drawBarnDoors` (was identical to `drawHorizontalSplit` — now edges-to-center reveal)
- Implemented `drawZoomBlocks` with Chebyshev distance block expansion
- Fixed `brightness` loop variable shadowing global
- Rewrote `TODO_SWIFT.md` — clean 17-item roadmap, ordered by impact

## Active codebase

| Path | Role |
|------|------|
| [`src/main.cpp`](src/main.cpp) | ESP32-S3 firmware — BLE GATT server, SD cache, dithering, 16 transitions |
| [`platformio.ini`](platformio.ini) | PlatformIO build config (ESP32-S3 devkit) |
| [`ios/SpotifyDisplay.xcodeproj`](ios/) | **Open in Xcode to build and run the iOS app** |
| [`SpotifyDisplay.swiftpm/Sources/SpotifyDisplay/`](SpotifyDisplay.swiftpm/Sources/SpotifyDisplay/) | Swift source files (BLEManager, ContentView, SpotifyManager, ImageProcessor, etc.) — compiled by the xcodeproj above |
| [`docs/BLE_PROTOCOL.md`](docs/BLE_PROTOCOL.md) | GATT UUIDs, packet formats, image layout — contract between firmware and app |
| [`TODO_SWIFT.md`](TODO_SWIFT.md) | **Polishing roadmap — start here for what's next** |
| [`resources/`](resources/) | ST7789 gamma reference notes |

## Roadmap

See **[`TODO_SWIFT.md`](TODO_SWIFT.md)** — 17 items ordered by impact across Priority 1 (core), Priority 2 (polish/reliability), Priority 3 (nice-to-have), and Future.

## Archived dev tools

| Path | What it was |
|------|-------------|
| [`python/`](python/) | Original desktop BLE sender + color tuning scripts — used to prototype the system before the iOS app existed. Not the current client. See [`python/README.md`](python/README.md). |

## Hardware

- Waveshare ESP32-S3 1.69" LCD dev board (ST7789VW, 240×240 IPS)
- MicroSD card for image cache (~32 GB)
- Physical iPhone required (BLE does not work on iOS Simulator)

Pin definitions and wiring in [`src/main.cpp`](src/main.cpp).

## Firmware setup

1. Install [PlatformIO](https://platformio.org/).
2. Open this folder; build and upload (`esp32-s3-devkitc-1` env).
3. Serial monitor at 115200 baud for debug output.
4. If you change the BLE GATT layout, update [`docs/BLE_PROTOCOL.md`](docs/BLE_PROTOCOL.md).

## iOS app setup

1. Open [`ios/SpotifyDisplay.xcodeproj`](ios/SpotifyDisplay.xcodeproj) in Xcode on a Mac.
2. Set your **Personal Team** and a unique bundle identifier for signing.
3. In the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard), register redirect URI **`spotifydisplay://callback`**.
4. Add your **Client ID** to [`SpotifyDisplay.swiftpm/Sources/SpotifyDisplay/Resources/Info.plist`](SpotifyDisplay.swiftpm/Sources/SpotifyDisplay/Resources/Info.plist) (key `SpotifyClientID`), or use the in-app override in Settings.
5. Run on a **physical iPhone** with Bluetooth enabled.

## Security

`python/.env` is gitignored — use `python/env.example` as the template. Never commit Spotify credentials. The iOS app stores tokens on-device only.

## License

[MIT](LICENSE) — not affiliated with Spotify AB.
