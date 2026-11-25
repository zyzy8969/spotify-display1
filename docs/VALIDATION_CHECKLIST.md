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
checks in each theme (Settings > look / Theme: Crayon and Quiet, each in day and night).

- Safe area, Face ID iPhone: the gear and status dots sit below the status bar / Dynamic Island,
  and the footer line ("47 saved" / "47 cached") sits fully above the home indicator.
- Safe area, home-button iPhone (SE) if available: nothing is clipped at the top, the footer has
  a small margin above the bottom edge, and the playback buttons are fully on screen.
- Art does not jump: skip to a song that is *not* cached and watch a fresh send. The cover must
  stay the same size and position from first byte to ACK, and while the error line or the
  "sending 62%" footer appears and disappears.
- Preview matches the keychain: during a fresh send the app keeps the previous cover while the
  strip fills, then crossfades to the new one at the moment the keychain shows it (both change
  together, within about a second). On a cache hit the app's cover changes as the keychain's
  transition finishes. With Reduce Motion on, the app cuts instead of crossfading.
- Strip: after a cache hit it shows a filled dot and a solid line; after a fresh send a hollow
  ring; while sending a growing line; while preparing a dashed line.
- Dynamic Type: Settings > Accessibility > Display & Text Size > Larger Text, largest size. Every
  screen stays usable (main screen scrolls if needed; dot names hide but the dots stay), nothing
  overlaps, buttons still work. Turn on Bold Text and check that Crayon text gets bolder.
- VoiceOver: dots read "Spotify connected" / "Display not connected"; the strip reads "Display"
  plus its state; playback buttons read "Previous track", "Play"/"Pause", "Next track"; the
  "show stats" switch reads as a switch with its on/off value; the theme options read "selected".
- Crayon strokes render without lag: rapid skips and a full fresh send with the main screen open
  stay smooth, with no visible stutter while the progress strip fills.
- Theme switching: changing the theme in Settings updates the open sheet and the main screen
  immediately, Quiet turns the status bar light, and the choice survives an app relaunch.
- Failed send recovers: start a fresh (uncached) send, then switch the board off or walk out of
  range mid-transfer. Once the app shows the error, the strip must not stay dashed. With the board
  switched off the app shows the new song's cover; after a send rejected with `ERROR:` (board
  still connected) both the app and the keychain keep the previous cover until the retry lands.
- Skip right after a cache hit: play a cached song, then skip at once to an uncached one. The
  preview must end on the new song's cover, never flip back to the cached song's cover.
- Settings, Transitions and Photo open as full-height sheets with no grabber and close by swiping down.
  Stats are no longer a sheet (see the section below).
- Client ID field: tapping it must not offer saved passwords above the keyboard.

## Status LED (WS2812B, GPIO15) — branch feat/status-led
- Boot: the LED is dark through the greeting and the waiting screen (no stray colour at power-up).
- Cached song: brief solid blue during the lookup and cache-hit draw, then a green flash that fades
  out in about 0.7 s.
- Uncached song: blue blink at the miss, dark while the phone downloads, then an orange pulse that
  gets brighter as the frame arrives; green flash once the cover is drawn.
- Prefetch of the next queued cover: the LED stays dark (nothing on screen changes).
- Skip during an orange pulse: the orange stops (dark or blue), and the new song gets its own colours.
- Disconnect mid-transfer: the LED goes dark.
- Brightness: comfortable through the case, not blinding. If too dim or bright, change
  `STATUS_LED_MAX` (26 of 255) in `src/main.cpp`.
- A red double blink means the board rejected data (`ERROR:*`). Note when it happens: a red blink right
  after a skip is the known stale-chunk race, not an LED bug.

## Transition picker, live mirror, stats pages, photo upload — branch feat/transition-picker-stats-upload (BLE 1.12)
Needs the new firmware flashed AND the new app build. Serial monitor on (`pio device monitor -b 921600`).
- Connect: Live tab terminal shows `rx CAPS:transitions` then `tx transition mask: 49 of 49 on`. With
  old firmware instead, Settings > Transitions shows the "older than 1.12" note and Photo refuses.
- Picker: Settings > Transitions lists 49 rows, each with a looping A/B example. "Quick only", "All off"
  and "All on" work; "All off" shows the "display will use all of them" note.
- Toggle test: switch everything off except ONE transition. Skip through 6+ songs (cached and new): the
  board must use only that effect every time (serial `Using transition: ...`), and the Live tab shows the
  same name. Then switch a different one on and confirm it joins the rotation.
- App vs board: on a cached song and on a new song, the in-app cover must play the same-named effect the
  board just drew (approximate look, same family; slightly later than the board). Reduce Motion = cut.
- Fresh draws announce: serial/Live tab show `TRANSITION:<name>` after a NEW (uncached) song too.
- Stats on the main screen: with "Detailed stats" on, tabs Now Playing | General | Live appear under the
  header; tap and swipe left/right switch them; vertical scroll still works; there is no Stats popup.
  General = last transfer, phases, averages, recent records (now with `tr <name>`). Live = last
  transition card, live status lines, scrolling terminal with tx/rx lines and transitions highlighted.
- Photo: tap the small photo icon in the header corner, pick a library photo: it is centre-cropped square
  and sent straight away (no sheet). The board draws it with a transition, serial shows NO `save` for it and the SD count does not rise. Spotify covers stay paused
  (banner "Photo on display"); "Back to Spotify" redraws the current song. Disconnect/reconnect clears the
  hold. Try a portrait, a landscape and a screenshot.
- Regression: rapid skips, disconnect mid-transfer, and a cache-hit-then-skip must behave as before.

## 2026-11-22 session — branch feat/faster-transfer, build #62 (BLE 1.15-1.18)

Check "app build 62" at the bottom of Settings first. Keep `pio device monitor -b 921600` open.

- [ ] Transitions: with every transition on, a run of skips gives a different one each time (serial
      `Transition pick: <name> (<index>) from <n> left`), new ones included (Honeycomb, Gallery, Doors...).
- [ ] Mirrored effects (Push Right, Block Rise, Cube Down) show the picture the right way round.
- [ ] Ripple is smooth (no tearing).
- [ ] Speeds vary 0.4x-1.3x on cache hits; a new song logs `Transition speed: 1.30x`.
- [ ] Album <-> photo: the app card flips and the keychain plays Card Flip both ways; the card behind always
      shows the other picture; after the first show, album -> photo is a cache hit (~1 s).
- [ ] Lighting (still being designed, see PROJECT_STATUS): played song = blue; saved-ahead new song = orange,
      blue flash at draw start, orange; new not on card = orange; app line matches at the same moments.
- [ ] Pop-ups (normal mode only) appear when the keychain turns green: "cache" / "cache"+"new" / "new";
      none for photos; going back to a song just played says "cache".
- [ ] Disconnect (phone Bluetooth off): the keychain shows the white "Bluetooth connected?" screen, never the
      text over the old cover. Repeat a few times.
- [ ] Nerd mode: live details right under the small cover row and its line (owner still reports it wrong).


## GIFs — branch feat/gif (BLE 1.25)

Flash this branch's firmware, install the matching cloud build, keep `pio device monitor -b 921600` open.
Paste your GIPHY key on the Photos page's GIFs tab (or Settings > Advanced) first.

- [ ] Boot log says `Animation buffers: ok`. (MISSING = no PSRAM to spare: GIFs stay off and the app says
      the firmware is too old.)
- [ ] GIFs tab opens on Trending; a search shows Results; ✕ goes back to Trending without a new GIPHY call
      (serial/app log quiet); "More" adds a page.
- [ ] Switching Photos <-> GIFs or reopening the page does not reload (no new results flash in).
- [ ] Tap a GIF: loading light while it sends (~5-10 s), then a transition and the GIF loops on the keychain
      at a normal pace, no tearing, right colours, stretched to the square (nothing cropped).
- [ ] The app's cover plays the same GIF, sharp pixels, same pace; the keychain and the cover stay in step.
- [ ] Tap the cover: back to the song on both; the cover stops animating.
- [ ] Tap one GIF, then quickly another: the second one ends up on the keychain. Tap a GIF, then pick a photo
      before it arrives: the photo wins.
- [ ] Make a GIF from a portrait and a landscape video: the slider moves the start (still updates), the bar
      fills, both come out the right way up, stretched.
- [ ] Close the Photos page mid-conversion: nothing appears on the keychain afterwards.
- [ ] Skip songs during a GIF send, disconnect mid-GIF, power-cycle: no half pictures; after reconnecting the
      song's cover is back (the GIF is gone, as designed).
- [ ] Covers and photos still send and cache-hit as before (the chunk/ACK code is now shared with GIFs).
- [ ] Reduce Motion on: grid thumbnails and the cover show stills.
