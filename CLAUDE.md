# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Spotify Display (`zyzy8969/spotify-display1`) — a digital keychain that shows live Spotify
listening as album art. Three cooperating parts:

- **ESP32-S3 firmware** (`src/main.cpp`, C++/Arduino via PlatformIO) — BLE GATT peripheral,
  SD-card album-art cache, 240x240 ST7789 LCD, 49 animated transitions (frame-composed ones use
  two extra PSRAM buffers, `prevBuffer`/`composeBuffer`).
- **iOS app** (`SpotifyDisplay.swiftpm/Sources/SpotifyDisplay/`, Swift/SwiftUI) — the active
  client: Spotify PKCE auth, ~1 Hz now-playing poll, art download, RGB565 conversion, BLE send.
- **Python tools** (`python/`) — archived prototype sender/color-tuning scripts. Not the active
  client; kept for reference.

Planned next: GIF support, peer-to-peer connection (see `docs/FUTURE_*.md`).

## Developer environment constraints (important)

The owner develops on **Windows and has no Mac — Xcode is unavailable locally.**

- Firmware: build/flash locally with PlatformIO. This is the only part testable on this machine.
- iOS app: Swift sources are editable, but **cannot be compiled locally.** The authoritative
  iOS build is the `ios` job in `.github/workflows/build.yml` (GitHub-hosted macOS runner),
  which uploads an unsigned `.ipa` artifact to sideload from Windows via Sideloadly/AltStore.
- **BLE and hardware cannot be tested from here.** Never state that hardware behavior is fixed.
  After each change, list concretely what must be verified on the physical device — see
  `docs/VALIDATION_CHECKLIST.md` for the standing on-device test script.

## Working rules

- **Work only on a new git branch. Never commit to `main`.**
- **Ask before**: deleting files, changing the BLE protocol, or changing pin/hardware config.
- The BLE protocol is a **shared contract** between firmware, the iOS app, and the Python
  scripts. If any of them changes, keep the others in sync, update `docs/BLE_PROTOCOL.md`
  (it carries its own version number), and say explicitly what changed.
- Small steps. After each, say what to verify on the device.

## Commands

### Firmware (PlatformIO, the one locally buildable target)

```powershell
pio run -e esp32-s3-devkitc-1
```

```powershell
pio run -t upload
```

```powershell
pio device monitor -b 921600
```

```powershell
pio device list
```

`platformio.ini` hardcodes `upload_port`/`monitor_port` as `COM6` (upload at 921600 baud); change it if the board
enumerates elsewhere. There is no firmware test suite (`test/` holds only a README).

### iOS app

```powershell
python ios/gen_xcodeproj.py
```

`ios/SpotifyDisplay.xcodeproj` is **generated** and compiles the same sources as
`SpotifyDisplay.swiftpm`. Re-run `gen_xcodeproj.py` from the repo root after adding or
renaming any Swift file under `SpotifyDisplay.swiftpm/Sources/SpotifyDisplay/`, or the cloud
build will not see it.

Cloud build (no Mac needed): push, or run the **Build** workflow from the Actions tab; download
the `SpotifyDisplay-unsigned-ipa` artifact. On a Mac the equivalent is
`xcodebuild -project ios/SpotifyDisplay.xcodeproj -scheme SpotifyDisplay ... build`.
`swift build` on the swiftpm package is unreliable in sandboxed environments and is not the
authoritative check.

### Python tools

```powershell
cd python; python -m venv venv; venv\Scripts\activate; pip install -r requirements.txt
```

Copy `env.example` to `.env` for `SPOTIFY_CLIENT_ID`/`SECRET`. `.env` is gitignored.

## Architecture

### Data flow

Spotify Web API (poll ~1 Hz) → art URL → download JPEG → `ImageProcessor` resize/grade/
Atkinson-dither → 115,200 bytes LE RGB565 → BLE cache-key probe → hit: firmware renders from
SD; miss: raw-DEFLATE the frame if the board sent `CAPS:deflate` (BLE_PROTOCOL 1.11) → chunked BLE
image write → (nothing drawn until complete) → firmware inflates (ROM `tinfl`, `rxPacked` → `rxBuffer`)
→ transition draw + SD save → ACK. The app also prefetches the next 5 queued covers (store-only).

### Firmware (`src/main.cpp`, ~1900 lines, single file)

The critical structural constraint: **BLE callbacks run on `BTC_TASK`, which has a tiny stack.**
Every callback class (`CacheCheckCallbacks`, `ImageTransferCallbacks`, `BrightnessCallbacks`,
`MyServerCallbacks`) does nothing but copy bytes and set a `volatile` flag
(`cacheCheckPending`, `imageTransferComplete`, `statsRequestPending`, `clearCachePending`).
All SD, display, and transition work happens in `loop()`, which has the large stack. Do not move
work into a callback — it overflows the stack and crashes the board.

`loop()` is the single owner of ordered state transitions, in this sequence: pending stats →
pending clear-cache → pending cache check (which first *resets* a partial `RECEIVING_DATA`
frame) → transfer-complete (copy rx → image, transition draw, SD save, then ACK) →
connect/disconnect UI. Exception: a cache
check waits one iteration while `imageTransferComplete` is pending, so a finished frame is drawn and
saved (under `transferCacheKey`, snapshotted at its header) before a hit can load over
`imageBuffer`. Disconnect recovery
and waiting-screen reset were deliberately consolidated into this one path to stop duplicate
resets; keep them there.

Transfer state machine: `WAITING_FOR_SIZE` → `RECEIVING_DATA` → `COMPLETE`. A valid header
arriving mid-frame is treated as a client resync and discards the partial frame.

Two PSRAM frame buffers: BLE chunks land only in `rxBuffer`, and nothing is drawn from it while
it fills (owner's choice, 2026-11-20: "whole image, then show" — no progressive draw). On
completion `loop()` copies rx → `imageBuffer` and draws it with a transition, like a cache hit.
`imageBuffer` is the picture on the panel (SD load/save, transitions). A transfer abandoned by a
skip or an app suspension therefore never changes the screen.

Cache: 16-byte MD5 key from the app, stored as `/cache/v1_<key>.bin` with a CRC32 trailer.
An in-memory index (`cacheIndex`, up to 1024 entries) is built at startup to avoid SD scans.
Writes are temp-write-then-rename; CRC mismatch deletes the file and reports a miss so the
client falls back to a full transfer. Firmware owns filename/version semantics — the app's key
is a hint. Telemetry goes out as `CACHE_COUNT:`/`CACHE_HEALTH:`/`CACHE_HIT_MS:` messages, and
clients must keep count parsing tolerant of the optional ones.

The ACK is deliberately sent **after** draw and SD save complete, not on last chunk received —
otherwise the phone starts the next image while `imageBuffer` is still being read (half frames).

**Dithering is the phone's job.** The app dithers during quantization; firmware draws the bytes
as received and never re-dithers. (Note: a comment near `imageTransferComplete` says
"Floyd–Steinberg" while the app actually uses Atkinson — the comment is stale; either way the
dithering happens app-side.)

### iOS app

- `BLEManager` — `CBCentralManager` with state restoration (`willRestoreState`), scans by GAP
  name `Spotify Display`, subscribes to Status/Cache/Image/Message, then **reads** Status
  because firmware's `READY` notify fires before the client has subscribed. Owns
  `processTrack` (cache probe → transfer), write-without-response queueing via
  `peripheralIsReadyToSendWriteWithoutResponse`, a `readyEpoch` guard that invalidates
  in-flight transfers across reconnects, a 32 s post-chunk SUCCESS timeout, and
  counted background time (`holdTransferBackgroundTime`/`releaseTransferBackgroundTime`):
  `SpotifyManager` takes a hold *before* launching a send and `processTrack` takes its own, so an
  overlapping cancelled send can't end the live one's background time.
- `SpotifyManager` — PKCE auth (no client secret; redirect `spotifydisplay://callback`),
  proactive token refresh, ~1 Hz currently-playing poll with HTTP 429 `Retry-After` cooldown,
  per-track failure cooldown plus global backoff after display errors, and
  `requestResync`/`lastSentToDisplayTrackId` to stop 1 Hz resend loops.
- `ImageProcessor` — JPEG decode → CIImage Lanczos resize + grade (one GPU render) → RGBA
  rasterize → Atkinson dither → packed LE RGB565.
- Views — `ContentView` (root: owns the managers, picks the screen, applies the theme),
  `NowPlayingView` (now playing + sending state, live strip, playback controls),
  `SignedOutView`, `SettingsView` (incl. theme picker), `StatsView` (transfer log + live
  details, shown when "show stats" is on). Views only *read* manager state.
- Theme system — `Theme` (token struct per theme, exposed as `\.theme` in the environment),
  `ThemeTypography` (text roles → fonts scaled with Dynamic Type), `ThemeCopy` (wording per
  theme), `CrayonShapes` (seeded wobble shapes and icons; wobble 0 = crisp for Quiet/Serif),
  `ThemeComponents`. Add a theme by adding a `ThemeID` case and its tokens, not new screens.
- `KeychainHelper` holds tokens; Client ID comes from `Resources/Info.plist`
  (`SpotifyClientID`) with a UserDefaults override in Settings.

## Known race-sensitive areas

Changes here need on-device stress testing (rapid skip, disconnect mid-transfer):

- `BLEManager` cache-hit confirmation timing — the app must wait for the authoritative
  `CACHE_RENDERED` message rather than showing optimistic cache-hit UI.
- `SpotifyManager` skip/resync sequencing and in-flight cancellation. Polls overlap and can
  answer out of order; `pollOnce` drops any answer older than one already applied (`pollSeq`)
  and ignores every recently replaced track for 3 s (`recentlyReplaced`); going back to a track
  replaced within 20 s needs 1.5 s of agreeing answers (`returnCandidateId`). It also drops answers
  whose Spotify `timestamp` is older than the newest seen (a lagging Spotify server; accepted after
  5 s so a real device switch still goes through). Without these, an old answer re-sends the
  previous song right after the new one is drawn.
- `src/main.cpp` partial-frame and transition sequencing during rapid track changes.
- Skip-render artifact: root cause found 2026-11-19 — cache replies carry no song id, so after a
  skip the old song's late reply was matched to the new song. The app now never sends a cache check
  while the board still owes a reply (`BLEManager.cacheReplyOwed` / `imageAckOwed`). Fix awaiting
  hardware verification; keep that invariant when touching the cache/transfer path.

## Project tracking

`PROJECT_STATUS.md` is the most recent state snapshot and wins over `TODO_SWIFT.md` (the longer
roadmap and bug backlog) where they disagree. `docs/DEV_HANDOFF.md` records what was last
committed and what still needs device verification.

The iOS UI follows the user's Design canvas mockup, which defines three user-selectable themes:
**Crayon** (default; white, hand-drawn crayon marks, Chalkboard SE), **Quiet** (dark, system
font, small colour accents) and **Serif** (white, Times New Roman, rules and dot leaders, one
rust accent). The theme is picked in Settings and stored under `@AppStorage("uiTheme")`. The
older monochrome `SpotifyDisplay_UI_Spec.md` is superseded; only its live strip under the art
and its "debug stats behind a Settings toggle" ideas were kept. The canvas's live serial log,
"+ gif" upload and 240x240 device-screen boards need firmware or BLE protocol changes and are
not built; ask before starting them.

## Hardware pins (do not change without asking)

LCD: BL 20, RST 42, DC 38, CS 39, MOSI 41, SCLK 40. SD: CS 17, MISO 16, MOSI 18, CLK 21.
Display 240x240, frame size 115,200 bytes. **Display SPI runs at 40 MHz — do not raise it.** 80 MHz
(above the ST7789's ~62.5 MHz rating) garbled transfers: covers logged as drawn never appeared, single
lines, stray squares (webcam-verified 2026-11-20). The S3's SPI clock is 80 MHz / integer, so there is
nothing between 40 and 80. `runTransition()` also resyncs the panel window with a 1x1 write first,
because Arduino_ST7789 caches CASET/RASET and one garbled command used to stick for several songs. Board needs PSRAM (`qio_opi`, 16 MB flash,
`huge_app.csv` partitions). `resources/` holds ST7789 gamma tuning references.
