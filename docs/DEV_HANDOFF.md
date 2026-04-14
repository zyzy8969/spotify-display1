# Dev handoff — iOS BLE / background work

Last updated: 2026-04-14

## What was committed

- **Info.plist:** `UIBackgroundModes` → `bluetooth-central`.
- **BLEManager:** Core Bluetooth state restoration (`CBCentralManagerOptionRestoreIdentifierKey`, `willRestoreState`, reconnect / rediscover services), `UIApplication.beginBackgroundTask` for the full `processTrack` scope, cancellable 32s post-chunk `SUCCESS` timeout.
- **ContentView:** `scenePhase`-aware copy about limited background Spotify updates + always-visible expectation line.
- **SpotifyManager:** Display failure cooldown (same track), short global backoff after any display error, and `lastSentToDisplayTrackId` when a transfer completes after the UI track has already changed (avoids 1 Hz resend loops).

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

- If timeouts persist: measure ESP32 serial from last chunk to post-process `SUCCESS`; tune the 32s ceiling in `BLEManager.sendRGB565`.
- If restore misbehaves on a specific OS version: narrow `applyRestoredPeripheral` for `.disconnecting` / edge states.
