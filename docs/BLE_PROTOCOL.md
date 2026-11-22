# BLE protocol (Spotify Display)

**Repository:** `spotify-display1` (root). Keep this file aligned with `src/main.cpp`, `python/spotify_album_sender.py`, and `SpotifyDisplay.swiftpm/Sources/SpotifyDisplay/BLEManager.swift`.

Version: **1.13** (45 more transitions, indices 52-96; enabled-transitions mask widened to 128 bits.)

Changes in 1.13 (more transitions). Additive and backward compatible both ways.
- **Transition indices 52-96 are valid.** 52-80 are quick threshold-map variants (inverses, mirrors and
  neon-edged versions of the quick set plus new Box/Plus/Wheel/Random Bars/Halftone maps; firmware
  `VARIANTS` table), 81-88 are mirrored versions of frame effects (Push Right, Card Stack Left, Cube Turn
  Reverse, Corner Peel Reverse, Accordion Reverse, Block Rise, Melt Up, Jelly Rise), 89-96 are Zoom Out,
  Infinite Zoom Out, CRT Off, Matrix Rain, Neon Scan, Glass Sweep, Pixelate, VHS Glitch. Names are the
  `TRANSITION:<name>` strings in `getTransitionName`. 52-80 count as quick (used for new songs).
  A forced index the board doesn't know (an older board) still means "random".
  97 Cube Up and 98 Cube Down were added later in 1.13. **Retired before release:** 75-80 (neon edges)
  and 92 (Matrix Rain); they are never picked at random and the app no longer lists them.
  99-116 are a slideshow set after PowerPoint 2003/2010 and Google Slides: Comb Horizontal, Comb Vertical,
  Cover Down, Uncover Left, Uncover Down, Fade Through Black, Newsflash, Strips, Wedge, Checkerboard
  Across, Honeycomb, Glitter, Shred, Gallery, Doors, Ripple, Flash, Fly Through (106-110 are quick).
  Every play now runs at a random speed of 0.4x-1.3x (firmware only; nothing on the wire changes).
- **Mask is 128 bits.** Same 20-byte write: magic + mask bits 0-63 (`u64` LE) + bits 64-127 (`u64` LE,
  the former padding). **Bit 127 set** marks a 1.13 mask; without it (a 1.12 app sends zeros) the board
  treats indices 64+ as enabled. 1.12 firmware ignores the upper half, so a 1.13 app works with it.

Changes in 1.12 (transition picker + photo upload). Additive: old clients, old firmware and the Python
sender are unaffected.
- **Enabled-transitions mask** — Cache characteristic write, 20 bytes: magic `0xCAC4E1EB` (u32 LE) +
  mask `u64` LE + 8 padding bytes. Bit *i* set = header transition index *i* may be picked at random
  (indices 0-51; retired 5, 10, 16 are ignored). It governs random picks only (`0xFF` headers and every
  cache hit); a forced header index is still honoured. A mask with no live bit set means "all enabled".
  The board keeps it in RAM only, so the app sends it on every connect. No reply. Fresh (new-song)
  draws normally pick from the quick set; if none of the quick ones is enabled they pick from whatever is.
- **Fresh draws announce their transition** — Message `TRANSITION:<name>` is now also sent after a fresh
  transfer is drawn, before the Image `0x01` ACK / `SUCCESS` (previously cache hits only). The iOS app
  replays that effect on its cover and shows it in the Live tab.
- **Display-only frame** — image header `transitionIndex` `0xFD`: draw the frame with a random enabled
  transition but do **not** save it to SD (photo upload). Same ACK as a normal frame. Needs no cache check
  first; the board ignores `transferCacheKey` for it.
- **Capability** — Message `CAPS:transitions`, sent with the stats reply (next to `CAPS:deflate`). Clients
  must send the mask and the `0xFD` header byte only after seeing it on the current connection (old firmware
  would treat `0xFD` as a random frame *and save it*, and log the mask write as a bad magic).
- The Python sender is unchanged (it never sends any of this).

Changes in 1.11 (faster sending). Additive: old clients and the Python sender are unaffected.
How 1.10 worked and how to roll back: `docs/ROLLBACK_FASTER_TRANSFER.md` (tag `backup/pre-faster-transfer`).
- **Compressed frame** — new 10-byte image header: `transitionIndex (1)` + `format (1)` = `0x01`
  (raw DEFLATE, RFC 1951, no zlib header) + raw size `uint32` LE (must be `115200`) + packed size
  `uint32` LE (1..115200). The body is that many bytes of the deflated RGB565 frame. Firmware inflates it
  once complete (ROM `tinfl_decompress`), then draws / saves / ACKs exactly as for a raw frame.
  `0xFE` store-only works the same with compression. If inflating fails or yields anything but 115,200
  bytes, nothing is drawn or saved and firmware sends `ERROR: Decompress failed` + Image `0x02`; the iOS
  app then sends raw frames for the rest of the connection.
- **Capability** — in reply to the stats request (`0xC0FFEEE1`), firmware that can inflate first sends
  Message `CAPS:deflate`, then `CACHE_COUNT` as before. Clients must send the 10-byte header only after
  seeing it on the current connection (old firmware rejects it as `ERROR: Invalid image header`).
- **Link parameters** (no GATT change) — on connect firmware asks for a 7.5–15 ms connection interval and
  251-byte LE data length. If the phone refuses or keeps an interval above 15 ms, firmware asks once for
  15 ms (the shortest Apple-compliant value). Outcomes are logged on serial (`BLE: Connection interval …`,
  `BLE: Data length …`).

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
   - 5-byte header: `transitionIndex (1 byte)` + payload size `uint32` LE (4 bytes). `0xFF` keeps random transition. `0xFE` = store-only (1.9): save to SD, don't draw.
   - Compressed (1.11): 10-byte header: `transitionIndex (1)` + `0x01` (raw DEFLATE) + raw size `uint32` LE (`115200`) + packed size `uint32` LE. Only after `CAPS:deflate`.
2. **Body**: consecutive chunks of RGB565 LE (or, after a 10-byte header, of its DEFLATE stream; the board inflates it before drawing). The **iOS app** applies Atkinson dither during quantization before sending; firmware draws nothing while the frame arrives (the previous picture stays up), then draws the whole frame with the header's transition and saves the same bytes to SD. The ESP32 does **not** re-dither.

**Client cancel / new transfer:** If a client stops mid-image and later sends a new transfer, the first write must be a valid 4-byte or 5-byte header. While still receiving a partial frame, firmware treats a valid header (4/5-byte with `115200` payload, or a well-formed 10-byte header) as resync and discards the partial frame.

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
| `TRANSITION:<name>` | Cache hit, right after `CACHE_HIT_MS`; since 1.12 also after every fresh draw, before the ACK | iOS: replayed on the cover, shown in the Live tab and the transfer log |
| `CAPS:transitions` | Stats request, next to `CAPS:deflate` (1.12) | iOS: may send the transitions mask and `0xFD` frames this connection |
| `CACHE_RENDERED` | Cache hit, after `TRANSITION` | Authoritative hit confirmation |
| `SUCCESS` | (a) after a frame's SD save, with Image `0x01`; (b) after a cache hit, right after the Cache `0x01` reply | (a) ends the transfer wait. (b) is redundant with `CACHE_RENDERED`; the iOS app accepts it only while it is waiting for a render confirmation, and ignores it otherwise |
| `CACHE_MISS_MS:<ms>` | Cache miss, before the Cache `0x00` reply | Telemetry only |
| `CAPS:deflate` | Stats request, before `CACHE_COUNT` (1.11) | iOS: may send compressed frames this connection |
| `CACHE_COUNT:<n>` | Stats request, and after a clear | Required for app UI |
| `CACHE_HEALTH:…` | Stats request | Optional telemetry |
| `CACHE_CLEARED`, `CACHE_CLEAR_MS:<ms>` | Clear request | See Cache check |
| `ERROR: <reason>` | Invalid header, size mismatch, buffer overflow, decompress failed (with Image `0x02`) | Fail the in-flight transfer |

Cache-hit order on the wire: `CACHE_HIT_MS` → `TRANSITION` → `CACHE_RENDERED` → Cache `0x01` → `SUCCESS`.

## Image format

- 240×240 pixels, **RGB565**, **little-endian** per pixel (low byte first).

## Roadmap (not implemented)

- Track-ID-based cache filenames (P2P / dedup).
- Custom 128-bit service UUID (multi-device ambiguity).
- Standard BLE Battery Service for display battery (requires hardware).
