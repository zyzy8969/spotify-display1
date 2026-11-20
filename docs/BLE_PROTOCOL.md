# BLE protocol (Spotify Display)

**Repository:** `spotify-display1` (root). Keep this file aligned with `src/main.cpp`, `python/spotify_album_sender.py`, and `SpotifyDisplay.swiftpm/Sources/SpotifyDisplay/BLEManager.swift`.

Version: **1.10** (New transition indices 28-51.)

Changes in 1.10: header `transitionIndex` values 28-39 are new transitions (Corner Peel, Shatter, Cube Turn,
Jelly Drop, Tile Spin, Infinite Zoom, RGB Split, Accordion, Ink Bleed, Crack Split, Sand Pile, Halftone), and
40-51 are quick ones (Quick Iris, Diamond Iris, Heart Iris, Clock Sweep, Bow Tie, Wind, Polka Dots, Rain
Columns, Wave Wipe, Venetian H, Spiral In, Luma Wipe). With `0xFF`, a fresh transfer picks only from the
quick set; a cache hit picks from all. Valid indices now end at 51; `0xFE` (store-only) and `0xFF` (random) are unaffected. All earlier indices are
unchanged.

Changes in 1.9 (prefetch): the app can put the *next* queued song's cover on the board's SD card ahead
of time, so that song's normal cache check is a hit. Two additions, both opt-in, nothing existing changes:
- **Probe** — Cache characteristic write with magic `0xDEADBEE0` + 16-byte key. Answered with the same
  1-byte Cache notify (`0x01` on SD / `0x00` not on SD) but the board **never loads or draws** and sends
  no `CACHE_HIT_MS` / `TRANSITION` / `CACHE_RENDERED` / `SUCCESS` messages.
- **Store-only transfer** — image header `transitionIndex` `0xFE`: the frame is received and saved to SD
  under the key of the preceding cache check / probe, **never drawn**. ACK is Image notify `0x01` only (no
  Message `SUCCESS`, which the iOS app also reads as a cache-hit render confirmation). Errors as usual.
  A cache check during a store-only frame discards it like any partial frame. `0xFE` is no longer a
  valid forced transition index (it never was a real one: indices end at 27, 51 since 1.10).
The Python sender never sends either and is unaffected.

Changes in 1.8: header `transitionIndex` values 17-27 are new transitions (Checker Cascade, Card Stack,
Static Dissolve, Dither Fade, Push Left, Crossfade, Card Flip, Tile Flip Wave, Block Drop, Melt, Zoom Punch).
Indices 5 (Slide), 10 (Curtain) and 16 (Zigzag) duplicated other transitions and are retired: random
selection skips them, and if forced they draw Wipe Left, Vertical Split and Barn Doors. Other indices are
unchanged. `0xFF` (random) is still what the iOS app sends. `TRANSITION:<name>` messages can carry the new names.

Changes in 1.7.1: documents Message notifies the firmware already sent but this file did not list
(`CACHE_HIT_MS:`, `CACHE_MISS_MS:`, `TRANSITION:`, and the `SUCCESS` that follows a cache hit). See
**Message reference**. Firmware, the iOS app and the Python tools are unchanged.

Changes in 1.7: firmware notifies Message `HB` every ~1 s while connected (see **Heartbeat**). Clients that
log or collect unknown messages must ignore it.

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

**Readiness must be read, not only awaited.** Firmware notifies `READY` from its connect callback, which fires before the client has discovered services or enabled notifications, so that notify is normally dropped. The Status characteristic is readable and holds `0x01` while connected (`0x00` after disconnect); clients should **read Status after subscribing**. The iOS app does this.

## Cache check (write to Cache characteristic)

**20 bytes**, little-endian:

1. **Magic** `0xDEADBEEF` (4 bytes) — cache lookup (draws on a hit), or `0xDEADBEE0` — probe (1.9: answers only, never draws).
2. **Key** (16 bytes) — MD5 digest of canonical identifier source (`album:<spotifyAlbumId>` preferred, fallback `url:<imageURL>`). App sends this hint; firmware owns filename/version semantics.

**Alternative magic** `0xC0FFEEE1` + 16 bytes padding — SD cache stats; firmware responds with:
- `CACHE_COUNT:<n>` (required for app UI)
- `CACHE_HEALTH:count=<n>,crc=<failures>,recoveries=<n>,ver=<cacheVersion>` (optional telemetry)

**Alternative magic** `0xCAC4E1EA` + 16 bytes padding — clear `/cache/*.bin`; firmware responds in order:
1) `CACHE_CLEARED` (authoritative clear ACK),
2) `CACHE_COUNT:0` (or post-clear count),
3) `CACHE_CLEAR_MS:<elapsedMs>` (timing metric).

**Notify response** (1 byte): `0x01` = image is cached on SD and was loaded; `0x00` = send image.
Firmware stores files with internal cache key version prefix (`v1_...bin`) and may keep backward compatibility with legacy unversioned entries.

On cache hit render completion, firmware also emits Message notify `CACHE_RENDERED` (authoritative board-render confirmation). Clients should prefer this over optimistic UI status.

On a hit, the `0x01` reply is sent only **after** the SD load and the full transition animation, which can take several seconds; the iOS app waits up to 8 s. If the file exists but fails to load (size/read/CRC error), firmware removes it and replies `0x00` (miss) so the client falls back to a normal image transfer.

## Image transfer (write to Image characteristic)

1. **Header**:
   - Legacy: 4-byte little-endian `uint32` payload size (random transition).
   - Current: 5-byte header: `transitionIndex (1 byte)` + payload size `uint32` LE (4 bytes). `0xFF` keeps random transition. `0xFE` = store-only (1.9): save to SD, don't draw.
2. **Body**: consecutive chunks of RGB565 LE. The **iOS app** applies Atkinson dither during quantization before sending; firmware draws nothing while the frame arrives (the previous picture stays up), then draws the whole frame with the header's transition and saves the same bytes to SD. The ESP32 does **not** re-dither.

**Client cancel / new transfer:** If a client stops mid-image and later sends a new transfer, the first write must be a valid 4-byte or 5-byte header. While still receiving a partial frame, firmware treats a valid header (`115200` payload) as resync and discards the partial frame.

**Notify**: `0x01` on Image characteristic and/or UTF-8 `SUCCESS` on Message **after** firmware finishes drawing (transition) and the SD cache save for that frame. Allow for the transition: up to ~1.3 s plus ~0.4 s save after the last chunk.

**Transfer error (optional, but recommended for the iOS app):** If the frame cannot complete or must abort while the client is in “waiting for SUCCESS”, firmware should NOTIFY:

- **Message (UTF-8)**: `ERROR:` prefix (e.g. `ERROR: Buffer overflow`, `ERROR: Size mismatch`, `ERROR: Invalid image header`, `ERROR: Cache load failed`).
- **Image (1 byte)**: `0x02` (failure), sent together with or shortly after the Message so clients can **`resume(throwing:)`** instead of waiting for the ~32s app-side timeout.

The iOS app treats both Message `ERROR:*` and Image `0x02` as an immediate failure of the in-flight transfer (same stage as SUCCESS negotiation).

**Partial receive vs cache check:** If a previous transfer was abandoned mid-chunk (`RECEIVING_DATA` with partial bytes), the next **Cache** write (lookup) is processed in `loop()` **before** hit/miss: firmware resets image receive state and discards the partial frame. Since nothing of a partial frame is ever drawn, an abandoned transfer leaves the screen unchanged.

## Heartbeat (1.7)

While a client is connected, firmware notifies UTF-8 `HB` on **Message** every **1 s**
(`HEARTBEAT_INTERVAL_MS` in `src/main.cpp`), from `loop()`, so it pauses while `loop()` is busy with a
cache-hit transition or SD save.

Why: iOS suspends a backgrounded app about 30 s after it leaves the foreground, which stops its Spotify
poll. With the `bluetooth-central` background mode, each notify on a subscribed characteristic wakes the
app briefly. The iOS app polls Spotify once per `HB` (skipped when its foreground poll ran in the last
0.8 s), so the display keeps up with song changes while the phone is locked, ~1 s behind at worst.

`HB` carries no state. Clients must not treat it as `READY`, `SUCCESS`, or a reply to any request.

## Message reference

Every UTF-8 notify the firmware sends on **Message** (`ffe4`), in `src/main.cpp`. Clients must ignore any
message they do not recognise.

| Message | When | Clients |
|---------|------|---------|
| `READY` | Connect callback (usually lost; read Status instead) | Readiness |
| `HB` | Every ~1 s while connected | iOS: background poll tick. Not a reply to anything |
| `CACHE_HIT_MS:<ms>` | Cache hit, after SD load + transition | Telemetry only |
| `TRANSITION:<name>` | Cache hit, right after `CACHE_HIT_MS` | iOS: shown in Stats |
| `CACHE_RENDERED` | Cache hit, after `TRANSITION` | Authoritative hit confirmation |
| `SUCCESS` | (a) after a frame's SD save, with Image `0x01`; (b) after a cache hit, right after the Cache `0x01` reply | (a) ends the transfer wait. (b) is redundant with `CACHE_RENDERED`; the iOS app accepts it only while it is waiting for a render confirmation, and ignores it otherwise |
| `CACHE_MISS_MS:<ms>` | Cache miss, before the Cache `0x00` reply | Telemetry only |
| `CACHE_COUNT:<n>` | Stats request, and after a clear | Required for app UI |
| `CACHE_HEALTH:…` | Stats request | Optional telemetry |
| `CACHE_CLEARED`, `CACHE_CLEAR_MS:<ms>` | Clear request | See Cache check |
| `ERROR: <reason>` | Invalid header, size mismatch, buffer overflow (with Image `0x02`) | Fail the in-flight transfer |

Cache-hit order on the wire: `CACHE_HIT_MS` → `TRANSITION` → `CACHE_RENDERED` → Cache `0x01` → `SUCCESS`.

## Image format

- 240×240 pixels, **RGB565**, **little-endian** per pixel (low byte first).

## Roadmap (not implemented)

- Track-ID-based cache filenames (P2P / dedup).
- Custom 128-bit service UUID (multi-device ambiguity).
- Standard BLE Battery Service for display battery (requires hardware).
