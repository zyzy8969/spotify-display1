# Dev handoff — iOS BLE / background work

Last updated: 2026-11-24

## What was committed

- **2026-11-24 (later), `feat/gif` (BLE 1.26):** GIF replay from the board's memory (cover <-> GIF flip
  like photos), Bayer dither for GIF frames, "GIFs take a little longer" note on the cover, GIPHY taps fixed
  (UIKit image view swallowed them), light style moved to Settings > Advanced, the app's GIPHY key built in by
  CI from the `GIPHY_API_KEY` secret (customers never paste a key), and the firmware clear-cache fix (it
  never deleted anything). Script: `docs/VALIDATION_CHECKLIST.md` "GIFs round 2".
- **2026-11-24, `feat/gif` (BLE 1.25, awaiting CI and device test):** GIFs. Photos page gains a GIFs tab:
  GIPHY search (owner's own key, Settings or the tab; nothing stored, GIPHY's terms) or 4 s of one video
  from a chosen start. 120x120 frames, stretched, no dither, max 48, one deflated "ANIM" transfer; firmware
  keeps them in two 2 MB PSRAM buffers and loops them in `loop()` (`animTick`), never on SD. The app's cover
  plays the same frames (`BLEManager.playingAnimation`). Shared `writeTransfer` now carries covers, photos
  and GIFs. Firmware builds with PlatformIO; Swift reviewed twice (ECC) but only CI compiles it. Script:
  `docs/VALIDATION_CHECKLIST.md` "GIFs". The start-up picture (starred photos) is a separate branch,
  `feat/startup-picture`; both touch `PhotoLibrary.swift`, `SettingsView.swift` and `BLEManager.swift`.

- **2026-11-22 (later), `feat/faster-transfer`, builds #48-#62 (BLE 1.15-1.18), all pushed, last firmware
  flashed:** build-46 transitions merged into the shared core, 0.4-1.3x speeds, swap Card Flip, photos cached
  on the card, `DRAWN` pop-up timing, new-song LED / app-line colours, per-track cache/new rule, separate
  nerd/normal layouts, white waiting screen fix, build number in Settings. **Paused mid-way by the owner:**
  lighting, cache/new/hit and the nerd layout are still being worked on (see `PROJECT_STATUS.md`
  "In progress"). Nothing verified on the device yet; script: `docs/VALIDATION_CHECKLIST.md` "2026-11-22 session".
- **2026-11-22, `feat/transition-picker-stats-upload` (BLE 1.12, awaiting device test, uncommitted):** transition on/off picker with live examples (mask sent to the board), fresh draws now announce `TRANSITION:`, the app cover replays the board's announced effect, stats moved from a sheet to General/Live pages on the main screen (Live has a terminal log), photo upload (display-only `0xFD`, not saved to SD, pauses Spotify). Firmware compiles with PlatformIO; the Swift side has NOT been compiled (no Mac) — run the CI `ios` job first. Test script: `docs/VALIDATION_CHECKLIST.md`.
- **2026-11-22, `feat/faster-transfer` (BLE 1.11, awaiting device test):** deflate-compressed frames, 7.5–15 ms interval + 251-byte DLE request, 5-song prefetch. Old behaviour and rollback steps: `docs/ROLLBACK_FASTER_TRANSFER.md`; pre-change code is tagged `backup/pre-faster-transfer`.
- **Info.plist:** `UIBackgroundModes` → `bluetooth-central`.
- **BLEManager:** Core Bluetooth state restoration (`CBCentralManagerOptionRestoreIdentifierKey`, `willRestoreState`, reconnect / rediscover services), `UIApplication.beginBackgroundTask` for the full `processTrack` scope, cancellable 8 s post-chunk `SUCCESS` timeout.
- **ContentView:** `scenePhase`-aware copy about limited background Spotify updates + always-visible expectation line.
- **SpotifyManager:** Display failure cooldown (same track), short global backoff after any display error, and `lastSentToDisplayTrackId` when a transfer completes after the UI track has already changed (avoids 1 Hz resend loops).
- **Firmware cache (`src/main.cpp`):** startup in-memory cache index, versioned cache filenames (`v1_*.bin` with legacy fallback), atomic temp-write + rename, CRC corruption counters/recovery deletes, deterministic clear flow with immediate count publish and timing telemetry.
- **BLE cache protocol usage:** firmware now emits cache telemetry messages (`CACHE_HEALTH:*`, `CACHE_HIT_MS:*`, `CACHE_MISS_MS:*`, `CACHE_CLEAR_MS:*`) while retaining `CACHE_COUNT:*` compatibility.
- **BLEManager clear cache:** waits for `CACHE_CLEARED` ACK before refreshing count (more reliable than fixed sleep).

## Build / tooling — known issues

- **`swift build`** from the terminal on this package may fail in restricted environments (e.g. Cursor sandbox: `sandbox_apply: Operation not permitted` when compiling `Package.swift`). **Authoritative compile:** open the Swift package / Xcode project on your Mac and build for **iOS Simulator or device**.
- **`nw_connection_*` / UDP** lines in the Xcode console are usually **Network.framework noise**, not BLE failures, unless you also see real transfer errors in the app.

## What still needs verification (you)

1. **Device:** foreground connect, art updates, no spurious retry storms.
2. **Background mid-transfer:** start a non-cached send, background the app — transfer should often complete within the OS background budget (not guaranteed).
3. **Restore:** kill app or relaunch near the display — restored central path should reconnect or fall back to scan.
4. **Long lock / long background:** Spotify polling will **not** stay real-time; UI copy documents that — if product needs continuous updates, that is a separate design (e.g. BG refresh / different entitlements), not fixed by `bluetooth-central` alone.

## Current priorities (roadmap alignment)

1. **Cache-check latency reduction (firmware-first):** optimize SD lookup path in `src/main.cpp` (album-id-aware cache key path already lands from app side).
2. **Reliability fixes:** brightness writes must always apply on hardware, and cache-clear command must always apply + refresh count in app.
3. **Transfer stability:** continue reducing occasional timeout / unsuccessful transfer cases under rapid track changes.
4. **Scope guard:** iOS transition picker is intentionally de-prioritized for now (protocol support exists, UI can wait).

## Optional follow-ups if tests fail

- If timeouts persist: measure ESP32 serial from last chunk to post-process `SUCCESS`; tune the 8 s ceiling in `BLEManager.sendRGB565`.
- If restore misbehaves on a specific OS version: narrow `applyRestoredPeripheral` for `.disconnecting` / edge states.
