# BLE protocol (Spotify Display)

**Repository:** `spotify-display1` (root). Keep this file aligned with `src/main.cpp`, `python/spotify_album_sender.py`, and `SpotifyDisplay.swiftpm/Sources/SpotifyDisplay/BLEManager.swift`.

Version: **1.1** (SUCCESS/notify timing after post-process ACK; matches current `src/main.cpp` and iOS `BLEManager`).

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

Subscribe to **Status**, **Cache**, **Image**, and **Message** notifications after discovery. Firmware signals readiness with status byte `0x01` and/or message `READY`.

## Cache check (write to Cache characteristic)

**20 bytes**, little-endian:

1. **Magic** `0xDEADBEEF` (4 bytes) — cache lookup.
2. **Key** (16 bytes) — MD5 digest of the **album image URL** (same key on Python and iOS).

**Alternative magic** `0xC0FFEEE1` + 16 bytes padding — SD cache **file count** stats; firmware responds with a `MESSAGE` notify: `CACHE_COUNT:<n>`.

**Notify response** (1 byte): `0x01` = image is cached on SD and was loaded; `0x00` = send image.

## Image transfer (write to Image characteristic)

1. **Size header**: 4 bytes, little-endian `uint32` — total payload bytes (expected **115200** = 240×240×2 RGB565).
2. **Body**: consecutive chunks of RGB565 LE; firmware may draw partial lines as data arrives, then applies Floyd–Steinberg dither and redraws full frame.

**Client cancel / new transfer:** If a client stops mid-image and later sends a **new** transfer, the first write must again be the **4-byte size header** (`115200` LE). While the peripheral is still in its receiving state with a **partial** frame, firmware treats a **4-byte** write that decodes to `115200` as a **resync** (discard partial data) so the following chunks belong to the new image. There is no separate cancel opcode.

**Notify**: `0x01` on Image characteristic and/or UTF-8 `SUCCESS` on Message **after** the firmware finishes dither, full redraw, and SD cache save for that frame. Until then, the phone must not start another image transfer (same `imageBuffer` on device). Typical latency is still well under common client ACK timeouts.

## Image format

- 240×240 pixels, **RGB565**, **little-endian** per pixel (low byte first).

## Roadmap (not implemented)

- Track-ID-based cache filenames (P2P / dedup).
- Custom 128-bit service UUID (multi-device ambiguity).
- Standard BLE Battery Service for display battery (requires hardware).
