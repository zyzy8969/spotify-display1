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

## Cache correctness

- Play a new album once, wait for transfer success.
- Replay same track/album and verify cache hit behavior on display.
- Run "Clear display cache" in app and verify `CACHE_COUNT` drops.
- Expected: cache misses after clear, cache refills correctly.

## Transition + rendering checks

- Test random transition mode (`255`) for at least 10 images.
- Test forced transitions with 3-5 different indices.
- Check for tearing/artifacts in diagonal/circular style transitions.
- Expected: transitions complete without frozen rows or stale regions.
