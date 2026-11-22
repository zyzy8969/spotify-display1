# Project Status — spotify-display1

Last updated: 2026-11-22 (end of session; owner paused work mid-way, see "In progress" below)

Branch: `feat/faster-transfer` (worktree `C:\Users\Zyan\Desktop\spotify-display1-led`), last cloud build
**#62** (app shows "app build 62" at the bottom of Settings). Firmware from the same commit is flashed on the
keychain (COM6). BLE protocol **1.18** (`docs/BLE_PROTOCOL.md`).

## In progress — owner will continue (NOT done, do not treat as settled)

1. **Status light / app line colours ("lighting situation").** Current rule (build 62), keychain LED and the
   app's progress line together:
   - cache hit on a song played before: blue only;
   - never-played song whose cover is already on the card ("saved ahead" by the queue prefetch, or the same
     album): orange from the start, a 250 ms blue flash when the board starts drawing it, then orange;
   - never-played song not on the card: orange only (transfer); all end with the green "done" flash.
   The owner said they still need to work on this. Code: firmware `LED_NEW` / `LED_BOTH` / `ledUpdate()`
   (stepped from `fwWaitUs` during transitions) in `src/main.cpp`; app `LiveStrip.lineColor`,
   `BLEManager.sendIsNewSong` / `aheadHitAt` (set on `TRANSITION_START`).
2. **"cache" / "new" / hit classification.** Changed many times this session; current rule (build 61+) is per
   Spotify **track** (`PlayedTracks`, `playedTrackIds.v2` on the phone, marked when the board says `DRAWN`):
   played before = "cache"; never played but on the card = "cache" AND "new"; never played and not on the card
   = "new". Pop-ups appear on the board's `DRAWN` (green light), never for photos, never in nerd mode. The
   owner said this still needs work. Earlier rules that were tried and replaced: per cover shown, per
   prefetched-unshown cover, per album id.
3. **Nerd mode layout: still reported wrong.** Build 59+ uses two separate layouts (`nerdPlayer` /
   `normalPlayer` in `NowPlayingView.swift`), swapped without animation; Live details sit directly under the
   small cover row and its progress line. The owner says it is still not right but has not sent a screenshot
   of build 59+. Next step: get a screenshot from the current build (check "app build N" in Settings) and
   where Live details should go, before changing it again.

## Done this session (awaiting on-device verification unless noted)

- 65 build-46 transitions (`feat/y2k-transitions`) ported into the shared core: 107 live, indices 0-116
  (75-80, 92 retired). BLE 1.15 (128-bit mask, 117 speed slots, `CAPS:t128`).
- Random speed 0.4x-1.3x (on by default); new songs always draw at 1.3x.
- Shuffle bag over all 128 indices with the hardware RNG; serial logs `Transition pick: ...`.
- Photo <-> cover swap: app card flips, keychain plays Card Flip (BLE 1.16 one-shot `CAPS:next`).
- Photos saved on the card under their own key: album -> photo is a cache hit after the first show.
- Back card behind the cover always shows the other picture (stale `onChange` copy removed).
- Pop-ups timed to the board's green light (BLE 1.18 `DRAWN`).
- Ripple rewritten (shading-only ring; the displacement tore).
- Waiting screen after a disconnect: panel window resync before the white fill (text used to land over the
  old cover).
- Settings shows the cloud build number (`CFBundleVersion` = GitHub run number).

## Next-session priorities

1. Owner's own pass on lighting and cache/new/hit (above); ask before changing those rules again.
2. Nerd mode layout, from a current screenshot.
3. Device run of `docs/VALIDATION_CHECKLIST.md`, section "2026-11-22 session".
4. Then: merge plan for `feat/faster-transfer` (many BLE versions since `main`).
