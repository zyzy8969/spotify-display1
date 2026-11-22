# Project Status — spotify-display1

**Snapshot: 2026-11-22.** Supersedes the 2026-04-15 snapshot. Architecture, race-sensitive areas and
the 40 MHz SPI decision are in `CLAUDE.md`. Where this file and `TODO_SWIFT.md` disagree, this file wins.

Git: this line of work is `feat/new-transitions` (0c8c17d, which merged `feat/themes-ui`) plus the
`chore/hygiene` worktree (HEAD 59d5742, fast boot). **None of the 2026-11 work is on `main`.** Local `main`
is at ae4e99b and `origin/main` at 2fcf2ba; neither contains this line.

## Current state

- **Firmware** (`src/main.cpp`, ~2800 lines, PlatformIO, `espressif32@6.5.0` / Arduino core 2.0.14):
  - Display SPI at 40 MHz (line 52). 80 MHz garbled transfers on hardware.
  - 49 usable transitions out of 52 slots (5, 10 and 16 retired). Indices 28-51 are new in protocol 1.10.
    Fresh transfers with `0xFF` pick from the quick set; cache hits pick from all.
  - Store-only frames (`0xFE`) and cache probes (`0xDEADBEE0`) from protocol 1.9.
  - Message `HB` every 1 s while connected (protocol 1.7).
  - Requests a 15 ms connection interval and the LE 2M PHY on connect (7a3b871, 5e8b523). Neither is in
    the protocol doc because they are link-layer settings, not protocol changes.
  - Brightness is PWM on LEDC channel 0 (`TFT_BL_PWM_CHANNEL`), not the GPIO.
  - Panel is cleared to black before the backlight comes on, and the backlight stays off until then.
  - Fast boot (59d5742): cache directory scanned by file name, white startup screen, BLE started before
    the greeting.
  - Cache files are `/cache/v1_<key>.bin` with a CRC32 trailer. `CACHE_KEY_VERSION` is still 1.
- **iOS app** (`SpotifyDisplay.swiftpm/Sources/SpotifyDisplay/`):
  - Three selectable themes (Crayon default, Quiet, Serif) under Settings, stored in `@AppStorage("uiTheme")`.
  - Album art is sized from the safe-area size, so it no longer resizes during a send (21f3473, 92e97fd).
  - The preview swaps to the new cover only when the keychain does (465b5d4, 5132dde).
  - Atkinson dither and RGB565 conversion run on the phone.
  - Timeouts are **8 s** for the cache-reply wait, the board-idle cap and the SUCCESS wait (see below).
  - Background transfers are held with `beginBackgroundTask`, and the 1 s heartbeat drives Spotify polling
    while locked.
  - The next queued cover is prefetched as a store-only frame (87cda77, 5e8b523).
- **Build**: firmware builds locally. The iOS app builds only in the cloud `ios` job (unsigned `.ipa`).
  The result of the most recent cloud build is not recorded in this repo. Check the Actions tab before
  any device session.

## Confirmed on hardware

- **Brightness works** (2026-11-19). Two causes, both fixed: `ledcWrite()` was given the GPIO instead of
  the channel, and the app pushed 0 when the setting was unset. Needed `espressif32@6.5.0` because core 3.x
  removed `ledcSetup`/`ledcAttachPin`.
- **40 MHz SPI is the working clock** (2026-11-20). At 80 MHz, covers were logged as drawn but never
  appeared, and some draws left single lines or stray squares. Owner confirmed 40 MHz works. Do not raise it.

## Done, awaiting hardware verification

Compiled in firmware locally. App changes compile only in the cloud build. None of these has a recorded
on-device pass. The device script is `docs/VALIDATION_CHECKLIST.md` plus the 2026-11-22 section of
`TODO_SWIFT.md`.

- **Skip-render artifact** (ac3633d, b0305d8). Root cause: cache replies carry no song id, so a skip let the
  old song's late reply answer the new song. The app now never sends a cache check while the board still
  owes a reply (`cacheReplyOwed` / `imageAckOwed`). The cleaner fix, echoing the cache key in every reply,
  is a protocol change and is not started.
- **Frame buffer overwrite** (e11a890). Finished frames are saved under `transferCacheKey`, and a cache check
  waits one loop while a completed transfer is pending.
- **Partial and stale frames on fast skips** (3a3f2b6, 7046add). Stale polls are dropped by `pollSeq`,
  `recentlyReplaced` and timestamp. A new song is shown only when its frame is whole.
- **Transfer and skip sequencing** (d2e8c98, fcdfcd3, cccfe45). In-app skips no longer resend the old song.
  Background transfers keep running. Token refresh is single-flight.
- **Heartbeat-driven background updates** (f934323). Needs a locked-phone test, not just a foreground one.
- **Three themes and safe-area layout** (21f3473, 92e97fd, 7f10c1a). Not yet run on a device.
- **Preview mirrors the keychain** (465b5d4, 5132dde). The app keeps the old cover during a send and swaps
  when the board ACKs.
- **Lower-latency link settings and prefetch** (7a3b871, 5e8b523, 87cda77). 15 ms interval and 2M PHY
  requested. Store-only prefetch of the next cover. Not measured.
- **New transitions 28-51** (5e8b523). Each needs one draw on hardware. Check the slowest against the 8 s
  SUCCESS wait.
- **Fast boot** (59d5742). Black panel, then white screen, then BLE before the greeting.

## Open issues

- **Image quality pass, not started.** One pass with before/after photos. Quantiser truncates instead of
  rounding (highest value). Grading clamp runs before the contrast filter it should follow. Double gamma
  (app grade plus panel registers). Download the largest art, not only 300x300. Bump `CACHE_KEY_VERSION`
  with it. No serpentine scan.
- **Auth hardening, not started.** `restoreSession()` reports network failures as "Session expired".
  Spotify's `error_description` is discarded. `KeychainHelper.save` ignores `SecItemAdd` status. No `state`
  parameter on PKCE.
- **Hygiene, not started.** `AgentDebugLog` still ships in `BLEManager.swift`, `SpotifyManager.swift` and
  `Extensions.swift`. CI does not fail on Swift warnings. `sdkconfig.defaults` is inert under
  `framework = arduino`. `src/main.cpp:52` passes GPIO1 as the LCD MISO; the LCD has no MISO, so this should
  be `GFX_NOT_DEFINED`. **Ask first**, since it is pin config. `SpotifyDisplay_UI_Spec.md` still sits at the
  root.
- **Stale "32 s" comments.** `BLEManager.swift:106` and `src/main.cpp:97` say 32 s. The code is 8 s. `CLAUDE.md`
  also says 32 s, and the owner has to change it.
- **Cache-check and transfer timing not measured on hardware.** `CACHE_HIT_MS` and `CACHE_MISS_MS` numbers
  are needed before and after any cache lookup change.
- **Docs behind the code.** `docs/VALIDATION_CHECKLIST.md` is dated 2026-04-15 and does not cover the prefetch,
  store-only, 2M PHY, fast boot or 40 MHz items. `docs/FUTURE_GIF_PIPELINE.md` still says frames go to `/anim`
  on SD, which the 2026-11-18 decision rejected (PSRAM only).
- **Not started, by design.** Still picture from camera roll. GIF search (GIPHY). Live log view (needs a
  protocol change and owner sign-off). Peer-to-peer similarity score.

**Removed from the open list (fixed in code):** album art resizing mid-download (21f3473, 92e97fd), and the
full-screen layout (92e97fd "fill the whole screen"). Both still need a device check. Brightness is
confirmed (above). The skip-render artifact is in "awaiting hardware" (above).

## In progress elsewhere (not merged into this line)

- **`feat/faster-transfer`** (153024f, a separate session): BLE transfer latency. MTU, DLE, connection
  interval (7.5 ms in that commit, against 15 ms here), deflate-compressed frames, prefetch five deep.
  **Frame compression changes the image body, which is a protocol change** (needs owner sign-off and a
  `BLE_PROTOCOL.md` version bump). Do not merge without that.
- **`feat/app-transition-mirror`** (cff31eb, unmerged): the app plays the same transition as the keychain,
  for all 49. This closes the "mirror the board's draw state" item that `TODO_SWIFT.md` still lists as open.

## Next priorities

1. **Hardware verification pass.** Use `docs/VALIDATION_CHECKLIST.md` and the 2026-11-22 section of
   `TODO_SWIFT.md`. Record with the webcam dashboard where it helps.
2. **Image-quality pass.** One pass, with before/after photos. Bump `CACHE_KEY_VERSION` in the same change.
3. **Hygiene and auth hardening.** Remove `AgentDebugLog`, pin the MISO fix (with sign-off), fix the stale
   comments, and close the auth items.
4. **Features.** Still picture from the camera roll first (app-only: `PHPickerViewController` into the
   existing RGB565 path, with a pinned mode). GIFs come after, PSRAM only, as decided 2026-11-18.
