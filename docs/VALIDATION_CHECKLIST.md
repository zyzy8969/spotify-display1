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

- Heartbeat (protocol 1.7): with the display connected, lock the phone, wait 2+ minutes, then skip
  tracks from the lock screen or Control Center.
- Expected: display follows each skip within ~1–2 s while the phone stays locked, and keeps doing so
  after 10+ minutes locked. Serial monitor shows no errors; app shows no spurious sign-out on unlock.
- Also try with the app swiped to background (not killed) instead of locked. Note: force-quitting the
  app from the app switcher stops it entirely; iOS does not relaunch force-quit apps for Bluetooth.

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

## iOS UI (themes)

Added with the three-theme UI (`feat/themes-ui`). Nothing here has been run yet. Repeat the visual
checks in each theme (Settings > look / Theme: Crayon, Quiet, Serif).

- Safe area, Face ID iPhone: the gear and status dots sit below the status bar / Dynamic Island,
  and the footer line ("47 saved" / "47 cached") sits fully above the home indicator.
- Safe area, home-button iPhone (SE) if available: nothing is clipped at the top, the footer has
  a small margin above the bottom edge, and the playback buttons are fully on screen.
- Art does not jump: skip to a song that is *not* cached and watch a fresh send. The cover must
  stay the same size and position from first byte to ACK, and while the error line or the
  "sending 62%" footer appears and disappears.
- Fresh-send preview: during a fresh send the new cover is revealed top-down with a line at the
  scan position and the previous cover below it, matching the board. On a cache hit the cover
  just changes.
- Strip: after a cache hit it shows a filled dot and a solid line; after a fresh send a hollow
  ring; while sending a growing line; while preparing a dashed line.
- Dynamic Type: Settings > Accessibility > Display & Text Size > Larger Text, largest size. Every
  screen stays usable (main screen scrolls if needed; dot names hide but the dots stay), nothing
  overlaps, buttons still work. Turn on Bold Text and check that Crayon and Serif text gets bolder.
- VoiceOver: dots read "Spotify connected" / "Display not connected"; the strip reads "Display"
  plus its state; playback buttons read "Previous track", "Play"/"Pause", "Next track"; the
  "show stats" switch reads as a switch with its on/off value; the theme options read "selected".
- Crayon strokes render without lag: rapid skips and a full fresh send with the main screen open
  stay smooth, with no visible stutter while the progress strip fills.
- Theme switching: changing the theme in Settings updates the open sheet and the main screen
  immediately, Quiet turns the status bar light, and the choice survives an app relaunch.
- Failed send recovers: start a fresh (uncached) send, then switch the board off or walk out of
  range mid-transfer. Once the app shows the error, the strip must not stay dashed and the art
  must not keep a scan line; both return to rest. Same after a send rejected with `ERROR:`.
- Skip right after a cache hit: play a cached song, then skip at once to an uncached one. The
  preview must end on the new song's cover, never flip back to the cached song's cover.
- Stats sheet opens at half height with a grabber and drags to full; Settings opens full height
  with no grabber. Both close by swiping down.
- Client ID field: tapping it must not offer saved passwords above the keyboard.
