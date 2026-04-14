# BLE protocol (Spotify Display)

**Repository:** `spotify-display1` (root). Keep this file aligned with `src/main.cpp`, `python/spotify_album_sender.py`, and `SpotifyDisplay.swiftpm/Sources/SpotifyDisplay/BLEManager.swift`.

Version: **1.3** (Atkinson dither during iOS quantization; ESP32 progressive draw + CRC32 cache + transition header + brightness char.)

## Peripheral

- **GAP name**: `Spotify Display` (iOS filters on this name when scanning.)
- **MTU**: Firmware requests **517** (512-byte payload typical). Clients should chunk writes using negotiated MTU (`maximumWriteValueLength` on iOS, 512 in Python reference).

## GATT

| Item | UUID |
|------|------|
| Service | `0000ffe0-0000-1000-8000-00805f9b34fb` |
| Status (notify) | `0000ffe1-0000-1000-8000-00805f9b34fb` |
| Cache (write + notify) | `0000ffe2-0000-1000-8000-00805f9b34fb` |
| Image (write + notify) | `0000ffe3-0000-1000-8000-00805f9b34fb` |
| Message (notify, UTF-8) | `0000ffe4-0000-1000-8000-00805f9b34fb` |
| Brightness (write, 1 byte 0..255) | `0000ffe5-0000-1000-8000-00805f9b34fb` |

Subscribe to **Status**, **Cache**, **Image**, and **Message** notifications after discovery. Firmware signals readiness with status byte `0x01` and/or message `READY`.

## Cache check (write to Cache characteristic)

**20 bytes**, little-endian:

1. **Magic** `0xDEADBEEF` (4 bytes) — cache lookup.
2. **Key** (16 bytes) — MD5 digest of the app-side cache key source (`album:<spotifyAlbumId>` preferred, fallback `url:<imageURL>`).

**Alternative magic** `0xC0FFEEE1` + 16 bytes padding — SD cache **file count** stats; firmware responds with a `MESSAGE` notify: `CACHE_COUNT:<n>`.
**Alternative magic** `0xCAC4E1EA` + 16 bytes padding — clear `/cache/*.bin`; firmware responds with `CACHE_CLEARED`.

**Notify response** (1 byte): `0x01` = image is cached on SD and was loaded; `0x00` = send image.

## Image transfer (write to Image characteristic)

1. **Header**:
   - Legacy: 4-byte little-endian `uint32` payload size (random transition).
   - Current: 5-byte header: `transitionIndex (1 byte)` + payload size `uint32` LE (4 bytes). `0xFF` keeps random transition.
2. **Body**: consecutive chunks of RGB565 LE. The **iOS app** applies Atkinson dither during quantization before sending; firmware draws partial lines as data arrives and saves the same bytes to SD. The ESP32 does **not** re-dither.

**Client cancel / new transfer:** If a client stops mid-image and later sends a new transfer, the first write must be a valid 4-byte or 5-byte header. While still receiving a partial frame, firmware treats a valid header (`115200` payload) as resync and discards the partial frame.

**Notify**: `0x01` on Image characteristic and/or UTF-8 `SUCCESS` on Message **after** firmware finishes SD cache save for that frame. Progressive line draw happens during transfer.

## Image format

- 240×240 pixels, **RGB565**, **little-endian** per pixel (low byte first).

## Roadmap (not implemented)

- Track-ID-based cache filenames (P2P / dedup).
- Custom 128-bit service UUID (multi-device ambiguity).
- Standard BLE Battery Service for display battery (requires hardware).
