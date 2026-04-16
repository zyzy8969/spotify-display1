# Spotify Display

An ESP32-S3 + iOS app project that displays Spotify album art on a 240x240 ST7789 screen over BLE.

## Current Status (Apr 2026)

### Working now
- Firmware cache path upgraded (A+B): in-memory index, atomic SD writes, CRC validation/recovery, deterministic clear-cache flow, and telemetry.
- Firmware-first cache semantics are live (versioned cache behavior and protocol updates).
- Disconnect waiting-screen reset is consolidated to a single owner path in firmware.
- iOS artwork URL fallback ordering and alternate URL retry are implemented.

### Active issues
- Cover art can resize during download and then return to normal.
- App layout still does not fill the intended screen area consistently.
- Intermittent skip-render artifact: after skip/reconnect, previous image may flash briefly before the correct next track.
- Root cause of that artifact is still TBD (cache status vs transfer/render sequencing).

For day-to-day tracking, see [`PROJECT_STATUS.md`](PROJECT_STATUS.md) and [`TODO_SWIFT.md`](TODO_SWIFT.md).

---

## Project Layout

| Path | Purpose |
|------|---------|
| [`src/main.cpp`](src/main.cpp) | ESP32 firmware (BLE GATT, SD cache, draw pipeline, transitions) |
| [`platformio.ini`](platformio.ini) | PlatformIO build config |
| [`ios/SpotifyDisplay.xcodeproj`](ios/SpotifyDisplay.xcodeproj) | Open in Xcode to build/run iOS app |
| [`SpotifyDisplay.swiftpm/Sources/SpotifyDisplay/`](SpotifyDisplay.swiftpm/Sources/SpotifyDisplay/) | Swift app source (`BLEManager`, `SpotifyManager`, `ContentView`, `ImageProcessor`) |
| [`docs/BLE_PROTOCOL.md`](docs/BLE_PROTOCOL.md) | BLE protocol contract between app and firmware |
| [`PROJECT_STATUS.md`](PROJECT_STATUS.md) | Session status snapshot |
| [`TODO_SWIFT.md`](TODO_SWIFT.md) | Roadmap and next priorities |
| [`resources/`](resources/) | ST7789 tuning notes/references |
| [`python/`](python/) | Archived prototype sender tools |

---

## Hardware

- Waveshare ESP32-S3 ST7789 display board (240x240)
- MicroSD card (cache storage)
- Physical iPhone (BLE testing on real device)

---

## Setup and Run

### Firmware (ESP32)
1. Install [PlatformIO](https://platformio.org/).
2. Build/upload firmware for `esp32-s3-devkitc-1`.
3. Use serial monitor at `921600` baud.
4. If BLE message formats change, update [`docs/BLE_PROTOCOL.md`](docs/BLE_PROTOCOL.md).

### iOS app
1. Open [`ios/SpotifyDisplay.xcodeproj`](ios/SpotifyDisplay.xcodeproj) in Xcode.
2. Set signing team and bundle identifier.
3. In [Spotify Developer Dashboard](https://developer.spotify.com/dashboard), register redirect URI `spotifydisplay://callback`.
4. Set `SpotifyClientID` in `Info.plist` (or use in-app override in Settings).
5. Run on physical iPhone with Bluetooth enabled.

---

## Roadmap

- Primary roadmap: [`TODO_SWIFT.md`](TODO_SWIFT.md)
- Current execution snapshot: [`PROJECT_STATUS.md`](PROJECT_STATUS.md)

If they differ, treat `PROJECT_STATUS.md` as the most recent state.

---

## Security Notes

- Never commit Spotify secrets/tokens.
- Keep local env/credential files out of git.

---

## License

This project is licensed under [MIT](LICENSE).  
Project is not affiliated with Spotify AB.
