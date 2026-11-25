# BLE protocol (Spotify Display)

**Repository:** `spotify-display1` (root). Keep this file aligned with `src/main.cpp`, `python/spotify_album_sender.py`, and `SpotifyDisplay.swiftpm/Sources/SpotifyDisplay/BLEManager.swift`.

Version: **1.26** (GIF replay: the board shows the GIF it still holds again, for the cover <-> GIF flip.)

Changes in 1.26 (2026-11-24; owner-approved). Additive: **GIF replay**, announced by `CAPS:replay` (after
`CAPS:anim`). Cache characteristic write, 20 bytes LE: magic `0xCAC4E1EE` + frame count `u16` + raw size
`u32` + packed size `u32` + 6 padding bytes, i.e. the identity of the last GIF the app sent. The board keeps
its last good GIF in PSRAM after a cover or photo replaces it on screen (until a new GIF arrives or the board
powers off; never on SD). If that identity matches, it draws frame 0 with a random enabled transition (or the
1.16 one-shot), loops it as in 1.25 and sends `TRANSITION_START` → `DRAWN` → `TRANSITION:<name>` → Cache
`0x01`. Otherwise it replies Cache `0x00` at once and the app sends the GIF again (1.25 transfer). Like a
cache check it waits for a finished transfer to be drawn and drops a partial one; it counts as an owed cache
reply. Firmware fix with no wire change: the clear-cache command (`0xCAC4E1EA`) now really deletes
`/cache/*.bin` (and leftover `.tmp`). It deleted by bare file name, which failed for every file, then
emptied the in-memory index anyway, so the app showed 0 while the card kept everything.
App: GIF frames are now ordered-dithered (8x8 Bayer, same thresholds as `DitherMode.bayer`), not rounded.

Version 1.25: GIFs: one 16-byte "ANIM" header + a deflated stream of every frame; the board loops it.

Changes in 1.25 (2026-11-24; owner-approved). Additive: a new **animation transfer** on the Image
characteristic (ffe3), announced by `CAPS:anim` in the stats reply (sent only when the board could set
aside its two 2 MB PSRAM buffers).
- **Header**, 16 bytes, LE: magic `0x4D494E41` ("ANIM" as bytes) + format `0x01` (raw DEFLATE; the only
  one) + frame side `120` or `240` + frame count `u16` (1-96) + raw size `u32` + packed size `u32`.
  Raw size must equal `count * 2 + count * side * side * 2`, at most 2 MiB; packed size 1..2 MiB.
- **Body**: the packed bytes, chunked like an image. Inflated, they are `count` frame delays (`u16` LE,
  milliseconds; the board clamps to 30-5000) followed by `count` frames of `side x side` RGB565 LE.
  A 120 frame is drawn pixel-doubled to 240x240.
- The board draws frame 0 with a random enabled transition (or the 1.16 one-shot), then sends the usual
  fresh-frame order (`TRANSITION_START` → `DRAWN` → `TRANSITION` → Image `0x01` → `SUCCESS`) and loops
  the frames from `loop()` at their delays. Never written to SD (GIPHY's terms forbid storing copies;
  a power cycle or disconnect ends it). Any non-probe cache check, any drawn image transfer, a new
  animation or a disconnect stops it; probes and store-only prefetches do not.
- Errors: `ERROR: Invalid animation header` (bad header) or `ERROR: Animation decompress failed`, both with
  Image `0x02`. Deliberately not `ERROR: Decompress…`, which makes the app send covers raw.
- A valid animation header mid-transfer is a resync, like an image header. A 1.24 board answers the
  16-byte header with `ERROR: Invalid image header`; the app only sends it after `CAPS:anim`.
- App: GIFs come from GIPHY search (the owner's own API key, Settings or the GIFs tab) or from 4 s of a
  video from a chosen start (12 fps). Nothing is saved on the phone. Frames are 120x120, stretched to the
  square (nothing cropped, like photos), rounded to 565 without dither (Bayer dither since 1.26), at most 48. The app's cover plays
  the same frames while the GIF is up.
  Python tools: not implemented (they never send animations).

Changes in 1.24 (2026-11-24; owner-approved). Additive: the status-light write (ffe6) may carry
`[... 12 bytes of 1.23 ..., gradient count, R, G, B x count]`, up to 31 bytes. Byte 13 = how many gradient
colours follow (0-6; more is read as 6), then that many RGB triples. `colour` (byte 3) gains `13` =
gradient: the loading pulse fades from each colour to the next, 1 s per colour, looping (one colour = that
colour; none = blue). Changing the colours while gradient is chosen previews them like any colour change.
A 1.19-1.23 board shows 13 as blue. No new `CAPS:`. App only (no wire change): Settings shows red, orange,
yellow, green, blue, indigo, violet, pink and white, then Rainbow / Wheel / Gradient; the swatches are sent as the
custom RGB (12), so the old named colours 0-10 are no longer sent (a saved one becomes custom with the
same RGB). The album song colour now takes the colour covering the most of the cover (it was the most
vivid one), keeps the cover's own saturation, and is gamma-decoded (2.2) for the LED's linear PWM, so
it looks like the cover on the screen. Colours picked on the app's colour wheel (static song colour,
custom loading colour, gradient colours; an LED-only wheel: hue and strength at full brightness) are gamma-decoded the same way before they are sent; the nine
swatches go as they are (tuned by eye on the LED).

Changes in 1.23 (2026-11-24; owner-approved). Additive: the status-light write (ffe6) may carry 12 bytes:
`[level, style, colour, preview, nothing playing, song mode, song R, song G, song B, custom R, custom G, custom B]`.
- `song mode` (byte 6): what consumer lights show while a song is on the board and nothing else is lit.
  `0` off (as before), `1` slow rainbow (one colour wheel per 8 s), `2` a static colour, `3` the album's
  colour. Bytes 7-9 are that colour's RGB (modes 2 and 3; the app works the album colour out from each
  cover it sees drawn, `AlbumLightColour`, and re-sends the write when it changes). The loading pulse and
  green confirm still play for every new cover; the song light fades in (0.4 s) after the green. The
  nothing-playing rainbow (1.22) wins over it. A new mode / colour shows at once if nothing else is lit,
  and ends a held loading-colour preview (1.21). Not saved on the board; the app sends it on every connect.
- `colour` (byte 3) gains `12` = custom: the loading pulse uses bytes 10-12 as RGB (the app's colour wheel).
  A 1.19-1.22 board shows 12 as blue.
Developer lights ignore bytes 6-12. Older firmware reads only the bytes it knows, so no new `CAPS:`. The
board has one status LED (a single WS2812B on GPIO15).

Changes in 1.22 (2026-11-23; owner-approved). Additive: the status-light write (ffe6) may carry a 5th byte,
`nothing playing`. `1` = the app is signed in to Spotify and no song is loaded (it shows "Play something on
Spotify"); `0` = a song is loaded (playing or paused). While it is `1` and nothing else is lit, consumer
lights loop a slow rainbow (one colour wheel per 6 s, below the loading pulse and the green / error lights).
Cleared on disconnect; the app sends it with every status-light write, so a reconnect restores it.
Developer lights ignore it. 1.19-1.21 firmware reads only the bytes it knows, so no new `CAPS:`. Also in
this firmware (no wire change): a fresh cover's green pulse is held at full brightness through its SD save
instead of sitting dark, and `STATUS_LED_MAX` is ~59% (was ~47%).

Changes in 1.21 (2026-11-23; owner-approved). Additive: the status-light write (ffe6) may carry a 4th byte,
`preview`. `1` = keep pulsing the loading colour now (the app's colour picker is open; a colour change while
held switches the colour in place); `0` = stop. The hold also ends with the next cache check, a disconnect,
or after 2 minutes. Consumer lights only; ignored while a cover is loading. 1.19-1.20 firmware already
ignores the 4th byte, so no new `CAPS:`. Rainbow loading colour: one turn per 0.8 s.

Changes in 1.20 summary: (more consumer loading colours, and a rainbow one.)

Changes in 1.20 (2026-11-23; owner asked for more colours). Same 3-byte ffe6 write as 1.19, more values
for its `colour` byte: `6` orange, `7` yellow, `8` cyan, `9` lavender, `10` coral, `11` rainbow (the pulse
also turns through every hue, one turn per 0.5 s; 0.8 s since 1.21). When a write changes the colour, a consumer board that
shows nothing else pulses the new colour twice (3.2 s) as a preview. A 1.19 board treats 6-11 as out of range and shows blue;
no new `CAPS:` message. App behaviour (no wire change): the "new" / "cache" pop-up words show only with
developer lights.

Changes in 1.19 summary: (consumer / developer status lights and the loading colour, on the ffe6 write.)

Changes in 1.19 (2026-11-23; owner-approved format). Additive: old firmware never announces `CAPS:lights`,
so the app keeps sending it the 1-byte write; old apps never send 3 bytes, so new firmware keeps its saved
style.
- **Status light write (ffe6) may carry 3 bytes**: `[level, style, colour]`.
  - `level` — as in 1.13 (0..255 of the safety cap, 0 = off).
  - `style` — `0` = consumer lights (default), `1` = developer lights (the per-song blue / orange / green of
    1.17-1.18). Other values = consumer.
  - `colour` — consumer loading colour: `0` blue, `1` purple, `2` white, `3` amber, `4` pink, `5` teal.
    Out of range = blue.
  A 1-byte write still sets only the level. Any other length is ignored (as before). The board saves
  `style` and `colour` in NVS (namespace `lights`), so its power-on light follows the last choice. Send the
  3-byte form only to boards that announced `CAPS:lights`: older firmware drops it, level included.
- **`CAPS:lights`** — sent on every stats request after `CAPS:newsong`.
- Consumer lights (firmware behaviour, no further wire change): white breathing (2.5 s) until a phone
  connects; one rainbow sweep (1 s) on connect; a pulse (1.6 s) in the loading colour from a cache
  miss reply (or a hit's `TRANSITION_START`) until `DRAWN`; then one short green pulse (0.5 s); slow amber blink (2 s) after a connection is
  lost; three red blinks on an error. Low battery / charging are stubbed (no charge-status pin; the battery
  sense is not read). Nothing flashes faster than ~3 a second: the developer saved-ahead flash and the red
  blinks now use 170 ms halves (were 150 ms).
- App behaviour (no wire change since 1.18): the blue / orange developer flash means "cover saved ahead by
  the app's queue prefetch, not drawn yet"; the 1.17 new-song magic is sent only for those. The board lights
  the LED next to the notify the app mirrors (`TRANSITION_START`, the miss reply, `DRAWN`).

Changes in 1.18 (2026-11-22). Additive: old apps ignore the message; old firmware never sends it (the app
then shows no "new" / "cache" word).
- **`DRAWN`** — Message notify sent the moment a cover is fully drawn, together with the green status LED:
  fresh frames right after the transition (before the SD save and the `SUCCESS` ACK), cache hits after the
  draw. Not sent for store-only (`0xFE`) frames. The app pops its "new" / "cache" word on it, so the word
  appears when the keychain turns green. Photos (`0xFD`) send it too; the app ignores it for them.
- App behaviour (no wire change): photos are no longer sent display-only. The app cache-checks a photo
  under its own key (MD5 of `photo:<md5 of the JPEG>` + dither suffix); a hit draws it from SD, a miss sends
  it with a `0xFF` header so the board saves it. The first show is a transfer, every later album -> photo
  swap is a cache hit. `0xFD` stays valid for other clients.

Changes in 1.17 summary: (new-song cache check: songs the keychain has never shown light the orange LED, even from SD.)

Changes in 1.17 (2026-11-22; owner asked for the orange light on every new song, prefetched ones too).
Additive: the app sends the new magic only to boards that announced `CAPS:newsong`.
- **New-song cache check** — same 20-byte Cache write as a normal check, magic `0xDEADBEE1`, sent for a
  song the app has never seen the keychain show (its own list of played track ids). Identical behaviour and
  reply; only the status LED differs: orange from the start; on a hit (saved ahead) a 250 ms blue flash, then
  orange while the cover draws, then green; on a miss the usual transfer orange. A song played before gets
  the plain check (blue). The app's progress line shows the same colours at the same time (it flashes on
  the hit's `TRANSITION_START`).
- **`CAPS:newsong`** — sent on every stats request after `CAPS:next`.
- Firmware note (no wire change): a new song's transition (fresh song transfer, or a new-song cache check)
  always runs at 1.3x, the top of the random range; the transition itself is still a random pick.
  `TRANSITION_START` reports that speed as usual.

Changes in 1.16 summary: (one-shot transition for the next draw: photo <-> cover swaps flip on the keychain.)

Changes in 1.16 (swap flip, 2026-11-22; owner asked for the keychain to flip like the app's card). Additive:
old firmware never announces `CAPS:next`, so the app never sends it the write; old apps ignore `CAPS:next`.
- **One-shot transition** — Cache characteristic write, 20 bytes: magic `0xCAC4E1ED` (u32 LE) + index (u8) +
  15 bytes padding. The next drawn frame that would otherwise pick at random (cache hit, `0xFF` or `0xFD`
  header) draws this index instead, once; retired or out-of-range indices are ignored. It expires after 15 s
  and on disconnect. No reply. Since 2026-11-23 (later) the app picks every draw's transition itself from the switched-on ones and sends it here right before each draw request (fresh song frames also carry it in the header byte), so the board never picks one the person switched off; the mask stays as the fallback. Before that it only sent Card Flip (23) right before the draw request of a photo <-> cover
  swap (the photo header, or the cache check for the cover coming back).
- **`CAPS:next`** — sent on every stats request after `CAPS:t128`.

Changes in 1.15 summary: (65 more transitions, indices 52-116; enabled-transitions mask widened to 128 bits; speeds for every index.)

Changes in 1.15 (build-46 transitions merged into the shared core, 2026-11-22; owner asked for them).
Additive and backward compatible both ways. This is what the `feat/y2k-transitions` branch (build 46) called
"1.13"; that number was already taken here by `TRANSITION_START`, so the same wire format ships as 1.15.
- **Transition indices 52-116 are valid.** 52-80 are quick threshold-map variants (inverses, mirrors and
  new Box/Plus/Wheel/Random Bars/Halftone maps; core `VARIANTS` table), 81-88 are mirrored versions of frame
  effects (Push Right, Card Stack Left, Cube Turn Reverse, Corner Peel Reverse, Accordion Reverse, Block Rise,
  Melt Up, Jelly Rise), 89-98 are Zoom Out, Infinite Zoom Out, CRT Off, (92 retired), Neon Scan, Glass
  Sweep, Pixelate, VHS Glitch, Cube Up, Cube Down, and 99-116 a slideshow set after PowerPoint 2003/2010 and
  Google Slides: Comb Horizontal, Comb Vertical, Cover Down, Uncover Left, Uncover Down, Fade Through Black,
  Newsflash, Strips, Wedge, Checkerboard Across, Honeycomb, Glitter, Shred, Gallery, Doors, Ripple, Flash,
  Fly Through. Names are `tx_name()` in the shared core. 52-80 and 106-110 count as quick.
  **Retired:** 75-80 (neon edges) and 92 (Matrix Rain): never picked at random, not listed in the app; forced,
  they draw Quick Iris / Rain Columns. All of them run in the shared core, so the app's live mirror plays
  them exactly too.
- **Mask is 128 bits.** Same 20-byte write: magic + mask bits 0-63 (`u64` LE) + bits 64-127 (`u64` LE, the
  former padding). **Bit 127 set** marks a 1.15 mask; without it (a 1.12-1.14 app sends zeros) the board
  treats indices 64+ as enabled. Older firmware ignores the upper half, so a 1.15 app works with it. An
  all-off mask still means "no transition" (1.13).
- **Speeds write may carry 117 slots** (122 bytes: magic + flags + one byte per index 0-116). 1.15 firmware
  also still takes the 57-byte 1.14 write (indices 52+ then run at the default). The app sends 117 slots
  only after `CAPS:t128`.
- **Random speed range is 0.4x-1.3x** (uniform; was 0.5x-2x log-uniform), and the app's per-transition
  slider is 40..130. The app now turns random speed on by default.
- **`CAPS:t128`** — sent on every stats request after `CAPS:speeds`.
- Firmware note (no wire change): the shuffle bag covers all 128 indices and picks with the hardware RNG;
  each pick logs `Transition pick: <name> (<index>) from <n> left in this round` on serial.

Changes in 1.14 (transition speeds, 2026-11-22; owner-approved). Additive: old firmware never announces
`CAPS:speeds`, so the app never sends it the new write; old apps ignore `CAPS:speeds` and the extra field.
The Python sender is unaffected.
- **Transition speeds** — Cache characteristic write, 57 bytes (the only cache write longer than 20):
  magic `0xCAC4E1EC` (u32 LE) + `flags` (u8; bit 0 = random speed) + 52 bytes, one per header transition
  index 0-51: `0` = default, `25`..`250` = that transition always runs at value/100 speed. Default is 1x,
  or, with the random flag, a random speed per draw in 0.5x..2x (log-uniform). The app uses 50..200 and
  sends it on every connect (after `CAPS:speeds`) and when the person changes it. No reply. RAM only.
  How speed works: frame-composed transitions (index >= 18) draw value-scaled fewer/more frames; the older
  drawn ones (0-17) scale their pauses, and when slowing down the board also stretches each step's
  drawing time. The shared core takes it as `tx_set_speed()`.
- **`TRANSITION_START` gains a 5th field** — `TRANSITION_START:<index>:<seed>:<expectedMs>:<oldBlack>:<speedPct>`.
  `speedPct` = the speed this draw uses x100 (e.g. `150`); `expectedMs` is already for that speed. Missing
  (1.13 firmware, or index 255 "none") = 100. Clients render the mirror at that speed.
- **`CAPS:speeds`** — sent on every stats request next to `CAPS:transitions`.

Firmware behaviour notes (2026-11-22, no wire change): fresh (new-song) frames with a `0xFF` header pick from
**every** enabled transition, the same as cache hits (they used to be limited to the quick set, see 1.11 /
1.12 below). Random picks use a shuffle bag: every enabled transition is drawn once before any repeats.

Changes in 1.13 (live transition mirror). Additive: old apps ignore the unknown message; old firmware never
sends it; the Python sender is unaffected.
- **All transitions off** — an enabled-transitions mask with no live bit set now means "no transition": random picks (`0xFF` headers, `0xFD` photos and every cache hit) draw the new frame at once and announce `TRANSITION_START:255:0:0:<oldBlack>`; index 255 = none (clients cut). In 1.12 an empty mask meant "all enabled".
- **Status LED brightness** — new optional characteristic `ffe6` (write, 1 byte). 0..255 scales the
  on-board WS2812B within its fixed safety cap (`STATUS_LED_MAX`, ~59% of full power since 2026-11-23, was ~47%): 255 = the cap
  (default after boot), 0 = LED always off. Not persisted on the board: the app re-sends its saved value
  on every connect, like screen brightness. Clients must treat `ffe6` as optional (older firmware lacks
  it). The service now reserves 30 attribute handles so it fits.
- **Transition start** — Message `TRANSITION_START:<index>:<seed>:<expectedMs>:<oldBlack>`, sent right
  before the board starts drawing a transition (after the 1x1 panel-window resync pixel, before the first
  transition draw). Sent for every drawn frame: cache hits, fresh covers and display-only `0xFD` photos.
  Never for store-only `0xFE` prefetch frames (they are not drawn).
  - `index` — decimal transition index that will actually be drawn: retired slots already resolved to
    their twin, and `0` (Wipe Up) when the board lacks the compose buffers and the pick was a
    frame-composed one (index >= 18).
  - `seed` — decimal `uint32` the board passes to the shared core's `tx_run`; it drives the random
    choices (Random Blocks, Crack Split). Same index + seed + frames = the same pictures.
  - `expectedMs` — that index's measured draw time from its last draw since boot, `0` if not drawn yet.
  - `oldBlack` — `1` if the old frame is all black (nothing was on the panel, so the board blanked its
    copy of the previous cover), else `0`.
- The transitions themselves now live in a shared C++ core
  (`SpotifyDisplay.swiftpm/Sources/TransitionsCore`), compiled into both the firmware and the iOS app, so
  the app can render the same frames as the board. `TRANSITION:<name>` and every other message are unchanged.


Changes in 1.12 (transition picker + photo upload). Additive: old clients, old firmware and the Python
sender are unaffected.
- **Enabled-transitions mask** — Cache characteristic write, 20 bytes: magic `0xCAC4E1EB` (u32 LE) +
  mask `u64` LE + 8 padding bytes. Bit *i* set = header transition index *i* may be picked at random
  (indices 0-51; retired 5, 10, 16 are ignored). It governs random picks only (`0xFF` headers and every
  cache hit); a forced header index is still honoured. A mask with no live bit set meant "all enabled" in 1.12; since 1.13 it means "none": random picks draw the new frame at once with no transition (announced as `TRANSITION_START:255:0:0:<oldBlack>`). Forced header indices still draw. After power-up every transition is enabled until the app sends a mask.
  The board keeps it in RAM only, so the app sends it on every connect. No reply. Fresh (new-song)
  draws picked from the quick set in 1.12/1.13; since 2026-11-22 they pick from every enabled one.
- **Fresh draws announce their transition** — Message `TRANSITION:<name>` is now also sent after a fresh
  transfer is drawn, before the Image `0x01` ACK / `SUCCESS` (previously cache hits only). The iOS app
  replays that effect on its cover and shows it in the Live tab.
- **Display-only frame** — image header `transitionIndex` `0xFD`: draw the frame with a random enabled
  transition but do **not** save it to SD (photo upload). Same ACK as a normal frame. Needs no cache check
  first; the board ignores `transferCacheKey` for it.
- **Capability** — Message `CAPS:transitions`, sent with the stats reply (next to `CAPS:deflate`). Clients
  must send the `0xFD` header byte only after seeing it on the current connection (old firmware would treat
  `0xFD` as a random frame *and save it*). The mask write is safe before it: old firmware only logs it as a
  bad magic, and no firmware replies to it. The iOS app therefore sends the mask right after `READY`, before
  its first cache check of the connection (so the first cover after a connect or board reboot already obeys
  it), and again once `CAPS:transitions` arrives. Writes on the Cache characteristic are handled in order,
  so the mask is in place before that cache check.
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
| Status LED (write: 1 byte level 0..255, 1.13; or 3 bytes level + style + colour, 1.19; + preview, 1.21; + nothing playing, 1.22; + song light + RGB + custom loading RGB, 1.23; + gradient colours, 1.24) | `0000ffe6-0000-1000-8000-00805f9b34fb` |

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
   - Animation (1.25): 16-byte "ANIM" header, every GIF frame in one deflated body. Only after `CAPS:anim`; see "Changes in 1.25".
2. **Body**: consecutive chunks of RGB565 LE (or, after a 10-byte header, of its DEFLATE stream; the board inflates it before drawing). The **iOS app** applies Atkinson dither during quantization before sending; firmware draws nothing while the frame arrives (the previous picture stays up), then draws the whole frame with the header's transition and saves the same bytes to SD. The ESP32 does **not** re-dither.

**Client cancel / new transfer:** If a client stops mid-image and later sends a new transfer, the first write must be a valid 4-byte or 5-byte header. While still receiving a partial frame, firmware treats a valid header (4/5-byte with `115200` payload, or a well-formed 10-byte header) as resync and discards the partial frame.

**Notify**: `0x01` on Image characteristic and/or UTF-8 `SUCCESS` on Message **after** firmware finishes drawing (transition) and the SD cache save for that frame. Allow for the transition: up to ~1.3 s plus ~0.4 s save after the last chunk.

**Transfer error (optional, but recommended for the iOS app):** If the frame cannot complete or must abort while the client is in “waiting for SUCCESS”, firmware should NOTIFY:

- **Message (UTF-8)**: `ERROR:` prefix (e.g. `ERROR: Buffer overflow`, `ERROR: Size mismatch`, `ERROR: Invalid image header`, `ERROR: Cache load failed`).
- **Image (1 byte)**: `0x02` (failure), sent together with or shortly after the Message so clients can **`resume(throwing:)`** instead of waiting for the ~8 s app-side timeout.

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
| `TRANSITION_START:<index>:<seed>:<expectedMs>:<oldBlack>[:<speedPct>]` | Right before every drawn transition starts (cache hit, fresh frame, `0xFD` photo; not `0xFE`) (1.13; `speedPct` since 1.14) | iOS: start the live mirror of the board's transition with the shared core, at that speed |
| `CAPS:speeds` | Stats request, next to `CAPS:transitions` (1.14) | iOS: may send the transition-speeds write this connection |
| `CAPS:t128` | Stats request, after `CAPS:speeds` (1.15) | iOS: transitions 52-116 exist; send speeds for all 117 indices |
| `CAPS:next` | Stats request, after `CAPS:t128` (1.16) | iOS: may send the one-shot next-draw transition (swap flip) |
| `CAPS:newsong` | Stats request, after `CAPS:next` (1.17) | iOS: may send the new-song cache check (orange LED) |
| `DRAWN` | A cover is fully on screen, with the green LED (1.18) | iOS: pop the "new" / "cache" word now |
| `CAPS:lights` | Stats request, after `CAPS:newsong` (1.19) | iOS: may send the 3-byte status-light write (style + loading colour) |
| `CAPS:anim` | Stats request, after `CAPS:lights`, only if the animation buffers exist (1.25) | iOS: may send 16-byte "ANIM" transfers (GIFs) |
| `CAPS:replay` | Stats request, right after `CAPS:anim` (1.26) | iOS: may send the GIF replay write (cover <-> GIF flip) |
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

Cache-hit order on the wire: `TRANSITION_START` (before the draw) → `CACHE_HIT_MS` → `TRANSITION` → `CACHE_RENDERED` → Cache `0x01` → `SUCCESS`.

Fresh-frame order (1.13): `TRANSITION_START` (before the draw) → `TRANSITION` (after draw + SD save) → Image `0x01` → `SUCCESS`.

## Image format

- 240×240 pixels, **RGB565**, **little-endian** per pixel (low byte first).

## Roadmap (not implemented)

- Track-ID-based cache filenames (P2P / dedup).
- Custom 128-bit service UUID (multi-device ambiguity).
- Standard BLE Battery Service for display battery (requires hardware).
