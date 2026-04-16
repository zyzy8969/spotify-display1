# Project Status — spotify-display1

Last updated: 2026-04-15 (end of session)

## Current state
- Firmware cache path is upgraded (A+B): in-memory cache index, atomic writes, CRC handling, deterministic clear-cache flow, and cache telemetry.
- BLE cache semantics updated with firmware-first ownership and cache-render confirmation message support.
- Disconnect recovery path in firmware is consolidated to a single owner in `loop()` to avoid duplicate waiting-screen resets.
- App pipeline includes artwork URL fallback ordering and alternate URL retry path.

## Confirmed completed recently
- Firmware cache speed/reliability improvements are in place on SD backend.
- Clear-cache ACK/count flow is more deterministic.
- App cache-hit flow now has confirmation hooks (`CACHE_RENDERED`/`SUCCESS`) to reduce false-positive UI.
- Disconnect waiting-screen reset refactor implemented in firmware.

## Open issues (active)
- Cover art size appears to change while downloading, then returns to normal after completion.
- App layout still does not fill the full intended screen area consistently.
- False cache-hit behavior is still observed in some skip/reconnect edge cases.
- On rapid skip, part of the previous image can draw briefly before the correct next track appears.

## Suspected hotspots for next session
- `SpotifyDisplay.swiftpm/Sources/SpotifyDisplay/ContentView.swift` (`AlbumArtView` sizing / layout behavior).
- `SpotifyDisplay.swiftpm/Sources/SpotifyDisplay/BLEManager.swift` (cache-hit confirmation timing and fallback flow).
- `SpotifyDisplay.swiftpm/Sources/SpotifyDisplay/SpotifyManager.swift` (skip/resync sequencing, in-flight cancellation timing).
- `src/main.cpp` (partial-frame and transition sequencing during rapid track changes).

## Next-session priorities
1. Stabilize album-art view sizing and full-screen layout behavior in SwiftUI.
2. Reproduce false cache-hit + stale-frame-on-skip with deterministic test sequence.
3. Tighten skip/resync and cache-confirm race handling across app/firmware boundary.
4. Re-validate with repeated skip/disconnect stress tests and capture before/after timings.
