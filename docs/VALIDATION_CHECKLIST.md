# Validation Checklist

Use this on a physical iPhone + ESP32 display before and after roadmap changes.
Last updated: 2026-04-15

## BLE transfer + track switching

- Connect display and confirm app shows `Display connected`.
- Start playback on Spotify and verify art appears on device.
- Skip tracks rapidly 5-10 times while transfer is in progress.
- Expected: no partial/corrupt frames, final frame matches current track.
- While transfer is active, power-cycle display or move out of range to force disconnect.
- Expected: display returns to waiting screen immediately and cleanly (no broken/misaligned waiting UI), then reconnects normally.

## Background behavior

- Start playback and lock the phone for 30-60 seconds.
- Unlock and confirm app reconnects/continues updates.
- Send one new track after unlock.
- Expected: no stuck transfer state; updates resume without app restart.
- While still on the same song, force a BLE reconnect (power-cycle display or move out/in range).
- Expected: current song is resent automatically without manually skipping tracks.
- Repeat disconnect/reconnect cycle at least 5 times in a row.
- Expected: waiting screen always restores correctly on disconnect and never gets visually corrupted.

## Cache correctness

- Play a new album once, wait for transfer success.
- Replay same track/album and verify cache hit behavior on display.
- Verify app cache-hit badge/status appears only after board render confirmation (`CACHE_RENDERED` / confirmation-compatible `SUCCESS`).
- Verify there is no false-positive "cache hit" state when the board did not visibly update.
- Run "Clear display cache" in app and verify `CACHE_COUNT` drops.
- Expected: cache misses after clear, cache refills correctly.
- Repeat clear-cache twice in a row and verify both runs are acknowledged (`CACHE_CLEARED`) and reflected in app cache count.
- Confirm firmware also emits `CACHE_CLEAR_MS:<n>` and that the app still refreshes count immediately after ACK.
- On repeated cache-hit playback, verify optional `CACHE_HEALTH:*` telemetry remains parse-safe (does not break count parsing).

## Brightness reliability

- Move brightness slider across low/mid/high values (e.g. 20, 128, 255) while connected.
- Expected: display backlight visibly changes on each write without reconnecting.
- Disconnect/reconnect display and verify last value is re-applied from app persisted setting.

## Transition + rendering checks

- Test random transitions for at least 10 images.
- Check for tearing/artifacts in diagonal/circular style transitions.
- Expected: transitions complete without frozen rows or stale regions.

## Latency checks

- In foreground, measure song-change-to-display time across 10 skips.
- Expected: median update latency is under ~1 second on stable BLE.
- Test tracks that have no exact 300x300 art but do have other sizes; expected: still displays via fallback + 240x240 conversion.
- Test a very small and a non-square source image; expected: still displays (center-cropped 240x240).
- Disable internet for 10-20 seconds, then restore it.
- Expected: app auto-recovers and updates current song without reopening app.
- Capture cache-check timing separately (cache-hit songs) before/after firmware cache-lookup optimization (`CACHE_HIT_MS`, `CACHE_MISS_MS`, serial lookup timings).
