# Validation Checklist

Use this on a physical iPhone + ESP32 display before and after roadmap changes.

## BLE transfer + track switching

- Connect display and confirm app shows `Display connected`.
- Start playback on Spotify and verify art appears on device.
- Skip tracks rapidly 5-10 times while transfer is in progress.
- Expected: no partial/corrupt frames, final frame matches current track.

## Background behavior

- Start playback and lock the phone for 30-60 seconds.
- Unlock and confirm app reconnects/continues updates.
- Send one new track after unlock.
- Expected: no stuck transfer state; updates resume without app restart.
- While still on the same song, force a BLE reconnect (power-cycle display or move out/in range).
- Expected: current song is resent automatically without manually skipping tracks.

## Cache correctness

- Play a new album once, wait for transfer success.
- Replay same track/album and verify cache hit behavior on display.
- Run "Clear display cache" in app and verify `CACHE_COUNT` drops.
- Expected: cache misses after clear, cache refills correctly.

## Transition + rendering checks

- Test random transitions for at least 10 images.
- Check for tearing/artifacts in diagonal/circular style transitions.
- Expected: transitions complete without frozen rows or stale regions.

## Latency checks

- In foreground, measure song-change-to-display time across 10 skips.
- Expected: median update latency is under ~1 second on stable BLE.
- Disable internet for 10-20 seconds, then restore it.
- Expected: app auto-recovers and updates current song without reopening app.
