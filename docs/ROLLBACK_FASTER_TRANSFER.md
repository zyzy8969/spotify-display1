# Rollback: before the "faster sending" change (BLE protocol 1.11)

Kept in case the 1.11 change (compressed frames, 7.5 ms interval + 251-byte packets, 5-song
prefetch) misbehaves on the device. It records how the system worked right before it and how to
get that back.

## Where the old version is

| What | Ref |
|------|-----|
| Last commit before the change | `59d5742` (fix(fw): fast boot …) |
| Backup tag on that commit | `backup/pre-faster-transfer` |
| The change itself | `153024f` on branch `feat/faster-transfer` |

The old code is still in git, so nothing has to be copied by hand.

## How the old system worked (protocol 1.10)

**Link setup (firmware `MyServerCallbacks::onConnect`)**
- Asked for a **15 ms** connection interval: `updateConnParams(bda, 12, 12, 0, 400)`.
- Asked for the LE 2M PHY (still done in 1.11, unchanged).
- MTU 517 (`BLEDevice::setMTU(517)`, unchanged).
- Did **not** request data length extension, and logged only the PHY result.

**Image transfer**
- The app always sent the frame **raw**: 115,200 bytes of dithered LE RGB565.
- Header was 5 bytes: `transitionIndex` + size `uint32` LE (`115200`). The firmware also accepted
  the 4-byte legacy header. There was no 10-byte header.
- Chunks went straight into `rxBuffer`. When complete, `loop()` copied rx → `imageBuffer`, drew it
  with a transition, saved it to SD and ACKed (Image `0x01` + `SUCCESS`).
- There was no `rxPacked` buffer, no `inflator`, no `CAPS:deflate` message and no
  `ERROR: Decompress failed`.

**Prefetch (app `SpotifyManager.schedulePrefetch`)**
- Once per current song, after a 1 s wait, the app read `/me/player/queue` and prefetched **only the
  first** eligible upcoming song: not the current track, not already prefetched, not the current
  album, and with art.
- Per song it sent one probe (`0xDEADBEE0`) and, on a miss, one store-only (`0xFE`) raw transfer.

**App stats line**
- `Sent new  <total> (dl <download>)`, with no size or ratio.

## How to roll back

Pick the smallest step that fixes the problem.

1. **Only compression is the problem.** Comment out the `CAPS:deflate` notify in `loop()` (the
   `statsRequestPending` block in `src/main.cpp`) and reflash. The app never compresses unless it
   sees that message, so every frame goes raw again. The interval/DLE request and deeper prefetch stay.
2. **Only the 7.5 ms request is the problem.** In `src/main.cpp`, set `CONN_INT_FAST_MIN` to `12`
   (min = max = 15 ms, the old request). To also drop DLE, remove the
   `esp_ble_gap_set_pkt_data_len(...)` line in `onConnect`.
3. **Only the deeper prefetch is the problem.** In `SpotifyManager.swift`, set `prefetchDepth = 1`.
4. **Everything.** Undo the whole change on a new branch (never on `main`):

```powershell
git checkout -b revert/faster-transfer feat/faster-transfer
```

```powershell
git revert 153024f
```

   Or start fresh from the backup tag:

```powershell
git checkout -b restore/pre-faster-transfer backup/pre-faster-transfer
```

   Then reflash the firmware (`pio run -t upload`) **and** reinstall the iOS app from that branch's
   cloud build. Mixed versions are safe in both directions: a new app with old firmware never sees
   `CAPS:deflate`, so it sends raw; an old app with new firmware sends 5-byte headers, which are still
   accepted.

After rolling back, check `docs/BLE_PROTOCOL.md` says **1.10** (a full revert restores it). If only
part was rolled back, add a note under 1.11 saying which part is disabled.
