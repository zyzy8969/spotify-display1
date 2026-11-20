# Agent Report — read-only analysis

Date: 2026-11-18 · Branch: `docs/agent-report` · Nothing was changed, built, or flashed.

Jargon is defined inline the first time it appears.

---

## 1. What this project is

A "now playing" picture frame: your iPhone watches what Spotify is playing, converts the album
cover into the exact pixel format the little screen understands, and pushes it to the ESP32 board
over Bluetooth Low Energy (BLE — short-range wireless for small messages). The board draws the
image with an animated transition and saves a copy to its SD card, so the second time you play
that album it redraws from the card instead of waiting for a transfer. The iPhone does all the
heavy lifting (download, resize, colour work, dithering); the board is deliberately dumb and
fast. The two sides are joined only by the BLE contract written down in `docs/BLE_PROTOCOL.md`.

```
   Spotify Web API
         │  poll ~1/sec: what's playing?
         ▼
┌─────────────────────┐        BLE (GATT)         ┌──────────────────────┐
│   iPhone app        │  ── cache probe ───────▶  │  ESP32-S3 firmware   │
│                     │  ◀─ hit 0x01/miss 0x00 ─  │                      │
│ SpotifyManager      │                           │ callbacks: set flag  │
│ ImageProcessor      │  ── 5-byte header ─────▶  │        │             │
│  240x240 RGB565     │  ── ~512-byte chunks ──▶  │        ▼             │
│  115,200 bytes      │                           │ loop(): draw + save  │
│ BLEManager          │  ◀─ SUCCESS / ERROR ────  │   ├─ ST7789 LCD      │
└─────────────────────┘                           │   └─ SD /cache/*.bin │
                                                  └──────────────────────┘
```

"GATT" is just BLE's way of exposing named mailboxes (characteristics) you can write to or
subscribe to. This project uses five: status, cache, image, message, brightness.

---

## 2. What I did and found

I read the firmware (`src/main.cpp`, 1918 lines), the five main Swift files, the BLE protocol doc,
and the three tracking docs. I did not build or run anything. I also checked the specific
suspicions you had already jotted at the top of `TODO_SWIFT.md` — most were real; one was not.

Ranked by how much they hurt you:

### 1. Brightness over BLE cannot work at all — `firmware`
`src/main.cpp:385` calls `ledcWrite(TFT_BL, brightness)`. `TFT_BL` is **20** (the GPIO pin
number). But setup uses the channel-based API: `ledcSetup(0, 5000, 8)` and
`ledcAttachPin(TFT_BL, 0)` at `src/main.cpp:1075-1076`, then `ledcWrite(0, ...)` at
`src/main.cpp:1077` and `:1110`. Your installed Arduino core is **2.0.17** (verified:
`framework-arduinoespressif32` 3.20017, `ESP_ARDUINO_VERSION_MAJOR 2`), where `ledcWrite`'s first
argument is a **channel**, not a pin. The ESP32-S3 has 8 channels, so channel 20 does not exist —
the BLE write is silently discarded. Your note says brightness "sometimes" fails; the code says
it should never work. One-line fix (`ledcWrite(0, brightness)`), but **I cannot confirm the
backlight responds without your hardware.**

### 2. The image buffer is overwritten while still being drawn and saved — `both`
This is my best candidate for the intermittent skip-render artifact you have not been able to pin
down, and it is worse than a cosmetic flash.

`imageState` is reset to `WAITING_FOR_SIZE` inside the BLE callback the instant the last chunk
arrives (`src/main.cpp:366-370`), *before* `loop()` has processed `imageTransferComplete`. So a new
header arriving immediately is accepted, and the resync path (`src/main.cpp:325-334`) zeroes
`receivedBytes` and clears `imageTransferComplete` while `loop()` may already be mid-draw or
mid-`saveToCache` reading that same `imageBuffer`. The firmware comment at the ACK says the client
"may send the next image only after this point" — but nothing *enforces* it, and the app breaks
that rule on purpose: `cancelOngoingTransfer` (`BLEManager.swift:176-200`) abandons the SUCCESS
wait and the next `processTrack` writes a fresh header right away.

Consequences, in order of nastiness: a half-old/half-new frame on screen (your flash); and that
same hybrid frame written to SD under the **previous** track's cache key. The CRC is computed over
the already-corrupted bytes at save time, so validation passes and the bad entry survives reboots
— it replays every time you hit that album, which is exactly the "intermittent, survives
reconnect" character you described. Clearing the cache would mask it temporarily.

### 3. BLE chunk loop can park forever waiting for a wakeup that already happened — `app`
`awaitWriteWindow` (`BLEManager.swift:585-592`) parks when the radio queue is full and relies on
`peripheralIsReady(toSendWriteWithoutResponse:)` to wake it. But that delegate is `nonisolated`
and hops to the main actor via `Task { @MainActor in … }` (`BLEManager.swift:898-903`), so the
wakeup can land while `writeDrainContinuation` is still `nil` — it resumes nothing and is lost.
Two separate defects here: the lost wakeup, and the unconditional `self.writeDrainContinuation = c`
which silently drops any continuation already stored (a leaked continuation hangs that task
permanently). Symptom: a transfer that stalls mid-image and then fails on timeout.

### 4. A stale timeout can kill a healthy transfer — `app`
The SUCCESS timeout task (`BLEManager.swift:464-486`) checks only `if let c = self.transferContinuation`
— it never verifies the continuation is the one it was created for. Your other three wait paths
all guard with a generation counter (`cacheCheckGen` at `:159`, `cacheRenderGen` at `:389`,
`clearCheckGen` at `:925`); this one does not. So a timeout armed for transfer A can fire against
transfer B's continuation and report `bleTimeout` on a transfer that was fine. Adding the same
generation guard makes it consistent with the rest of the file.

### 5. Album art resizes during download — `app`
`AlbumArtView` (`ContentView.swift:218-243`) wraps a greedy `GeometryReader` and then applies
`.aspectRatio(1, contentMode: .fit)` *outside* it, while sitting in a `VStack` whose siblings
appear and disappear during a transfer: the progress bar (`:17-23`) and then the
`lastTransferResult`, `boardAckStatus` and `lastTransitionName` badges (`:51-83`), one at a time.
Each appearance changes the height offered to the art, so `side = geo.size.width` is recomputed
and the image visibly jumps, then settles. This is the exact symptom in `PROJECT_STATUS.md`.

### 6. The layout fights the safe area — `app`
`.ignoresSafeArea()` at `ContentView.swift:138` is applied with no edge argument to the whole
`VStack`, so it also extends the *bottom* bar under the home indicator — the 44×44 settings button
(`:116-123`) has only `.padding(.bottom, 6)` beneath it. Meanwhile the comment at `:14` claims the
art "extends into top safe area", which the code does not actually arrange. That combination is
your "layout does not fill the intended screen area consistently".

### 7. The current UI diverges from the redesign spec in more than colour — `app`
I found `SpotifyDisplay_UI_Spec.md` outside the repo, at `C:\Users\Zyan\Downloads\`. Read against
it, the gap is wider than the colour issue:

- **Colours:** `.cyan`/`.green` (`ContentView.swift:56`), `.green` (`:61`), `.purple` (`:75`),
  `.orange` (`:107`). Spec: white, black and greys only.
- **Background:** code uses flat `Color.black` (`:138`). Spec wants the dark background *derived
  from the album art* — blurred and desaturated.
- **Art size:** code renders the art full-width (`:218-243`). Spec wants **~300 pt max width,
  centred, 6 pt corners, subtle shadow, crossfade on track change**. This is useful — it gives
  finding 5 a concrete target instead of a guess.
- **The live strip does not exist.** Spec replaces all the text badges with a single 2 px strip
  under the art: full-opacity white for a cache hit, ~25 % white for a fresh download, no text.
  Implementing it **also removes the cause of finding 5**, because the appearing/disappearing
  badges are what shift the layout.
- **Bottom row:** spec wants exactly one line, `47 cached · Sent 2s ago`. Code has a multi-item
  `HStack` of dots, labels and counts (`:102-125`).
- **Settings:** spec wants an Appearance picker (Dark/Light/System), a "Live updates" toggle that
  actually gates the poll timer, and a "Show detailed stats" toggle. Code has only
  `@AppStorage("showDebugInfo")` (`:10`); the spec's keys are `appearance`, `liveMode` and
  `showDetailedStats`, so this is a rename plus two new settings.

Two things to flag before anyone implements it:

1. **Spec section 3 suggests adding a notify characteristic** pushing `{hit, totalCached}`. That
   would be a **BLE protocol change**, which your rules say I must ask about first — but I do not
   think it is needed. The firmware already emits `CACHE_COUNT:`, `CACHE_RENDERED` and `SUCCESS`
   (`src/main.cpp`, and `BLEManager.handleMessage` already parses all three). Every field the spec
   lists can be derived app-side with **no firmware change and no protocol bump**. I would take
   that route unless you want the other one.
2. **Spec section 5 says to recover a `ContentView.swift` draft from an earlier chat.** I have no
   access to your past conversations, so that draft is lost to me. I would implement from the spec
   text directly.

### 8. Debug instrumentation from an old Cursor session is shipping in the app — `app`
`AgentDebugLog` (`Extensions.swift:27-72`) hardcodes session id `de5a9b`, writes NDJSON log lines
to the app's Caches directory on every transfer, and is called from eight places in `BLEManager`
(`:193, :453, :470, :491, :622, :647, :861, :873`). It is dead weight on a real phone and grows
unbounded. This is code-quality debt, not a bug.

### 9. Two transitions are pathologically slow and block the radio — `firmware`
`drawCircularWipe` (`src/main.cpp:478-499`) and `drawDiagonalWipe` / `drawDiagonalWipeInverse`
(`:538-571`) rescan all 57,600 pixels on every animation step and push `gfx->drawPixel` one pixel
at a time — roughly 3.3M and 6.9M loop iterations respectively, each pixel its own SPI
transaction. The other transitions correctly use `draw16bitRGBBitmap` for whole rows. Because this
runs inside `loop()`, BLE is unserviced throughout, and it is why a cache hit needs an 8-second
client-side timeout to be safe.

### 10. The docs disagree with the code on the timeout — `both`
`BLEManager.swift:466` waits **8 seconds** (`8_000_000_000` ns). `docs/BLE_PROTOCOL.md` says
"~32s app-side timeout" and `docs/DEV_HANDOFF.md` says "cancellable 32s post-chunk SUCCESS
timeout". The code is the truth; the docs are stale.

### 11. The image header has no magic number — `firmware`
In `RECEIVING_DATA`, any 4- or 5-byte write that happens to decode to 115,200 is treated as a
resync header (`src/main.cpp:311-334`). Real pixel data hitting that value is vanishingly
unlikely, but the cache and clear commands both use magic numbers and the image header does not.
Cheap robustness win — **and a protocol change, so I would need your go-ahead.**

### 12. Cosmetic comment/code mismatches — `firmware`
The enum says `TRANSITION_BARN_DOORS` opens "from center" (`:124`) but `drawBarnDoors` (`:678`)
reveals edges→centre. `TRANSITION_HORIZONTAL_SPLIT` (`:121`) actually splits along Y (vertically).
`drawHorizontalSplit`'s "~1 second total" comment (`:654`) is really ~0.5 s (40 steps × 12.5 ms).
Harmless, but they mislead whoever reads next.

### Not a bug after all
Your note listed "4-byte cache key truncation". I could not reproduce it: all three senders use
the full 16-byte MD5 — `Extensions.swift:6-10`, `python/spotify_album_sender.py:180`, and the
firmware copies 16 bytes at `src/main.cpp:263` and compares 16 at `:1308`. Either it was already
fixed or it was a misread. Nothing to do.

---

## 3. What you should do next to test

Do these in order. Items 1–4 work on the **broken-screen board over serial only** — the serial log
tells you what the firmware thinks is happening even with no usable panel.

1. **Confirm the toolchain and get a clean build.** Run `pio run -e esp32-s3-devkitc-1`.
   *Working:* compiles with no errors; the summary names `esp32-s3-devkitc-1`.
   *If not:* paste the error — most likely a missing PlatformIO core or the `GFX Library` dependency.

2. **Find the real COM port and open the serial monitor** (broken-screen board). `platformio.ini`
   assumes `COM3`. Run `pio device list`, then `pio device monitor -b 921600`.
   *Working:* on reset you see the SD card info block, then `BLE: Sent READY signal` once your
   phone connects.
   *If not:* wrong port, or the baud rate is mismatched and you get garbage characters.

3. **Confirm the BLE handshake and MTU** (broken-screen board, serial only). Connect the app.
   *Working:* `BLE Client connected`, then `BLE: Negotiated MTU = 517 bytes`.
   *If you see MTU below 200:* the firmware prints a warning and transfers will be slow — that is
   a phone/OS negotiation issue, not your code.

4. **Reproduce the brightness bug deliberately** (broken-screen board, serial only). Move the
   brightness slider in the app.
   *Working-as-broken:* serial prints `BLE: Brightness set to 128` **even though nothing changes**
   — that proves the write arrives and the bug is the LEDC channel, confirming finding 1 without
   needing to see the panel. The backlight LED may still glow even with a cracked panel; if you can
   see it not changing while serial reports the new value, that is the confirmation.
   *If no serial line appears at all:* the problem is earlier — the characteristic write is not
   reaching the board, which is a different bug.

5. **Switch to the good board and confirm a plain transfer end to end.** Play a track not played
   before.
   *Working:* art appears progressively, top to bottom, then `BLE: Image transfer complete` and a
   `SUCCESS`; the app shows "Sent to display".
   *If it times out at ~8 s:* suspect finding 3 or 4, and capture the serial log around the last
   chunk.

6. **Hunt the skip artifact (finding 2) with a deterministic sequence.** Clear the cache from the
   app first. Play album A, and **while the art is still drawing**, skip to album B; repeat 10
   times with fresh albums.
   *Working:* every final frame matches the current track, with no flash of the previous one.
   *If you see a flash, or a frame that is half one album and half another:* that is finding 2
   confirmed. Note the track, then replay that same album later — **if the corrupted image comes
   back from cache, that confirms the poisoned-cache half of the diagnosis**, which is the more
   important half.

7. **Watch cache-hit latency.** Replay an album you know is cached and time it.
   *Working:* the board redraws within roughly a second or two.
   *If it takes 5 s or more:* you have landed on one of the per-pixel transitions (finding 9); the
   serial `TRANSITION:` line names which one, so note it.

8. **Stress disconnect recovery.** Mid-transfer, power-cycle the display; repeat 5 times.
   *Working:* the waiting screen returns cleanly every time and the current song resends by itself
   without you touching skip.
   *If the waiting screen is garbled or the song does not resend:* capture the serial log; this is
   the disconnect path that was recently consolidated.

I cannot do any of steps 2–8 for you — they all need the board and the phone.

---

## 4. Getting the app onto your iPhone without a Mac

Prices and limits below were read from the official pages today, 2026-11-18; sources at the end of
the section.

**Important finding that changes the maths: your repository is public.** GitHub's billing docs say
standard GitHub-hosted runners are **free in public repositories** and that usage "does not reduce
the included compute usage". So the macOS build you already have in `.github/workflows/build.yml`
costs you **nothing today**, and the $0.062/min macOS rate only starts to matter if you make the
repo private.

| Option | Cost | Setup effort | Key limits | Verdict |
|---|---|---|---|---|
| **GitHub Actions + Sideloadly** | $0 (public repo) + $0 tool | Low — the workflow already exists and works | App dies after **7 days**; **3 apps per device**; needs iTunes + iCloud (web versions, not Microsoft Store) on Windows; Developer Mode on iOS 16+ | **Recommended now.** Already built; cost is zero. |
| **GitHub Actions + AltStore Classic** | $0 | Medium — needs AltServer running on your PC | Same 7-day signing limits; AltServer must be reachable on Wi-Fi to auto-refresh | Good *if* the 7-day re-signing annoys you — it automates the refresh. AltStore's own site states no price. |
| **AltStore PAL** | Not stated on altstore.io | n/a | Available **only in the EU, Japan and Brazil** — not the US | Ignore unless you are in one of those regions. |
| **Paid Apple Developer Program** (still building in CI) | **$99/year** | Low — same pipeline, you just add signing | Lifts expiry to **1 year** and allows more simultaneous installs (per Sideloadly's FAQ) | **Buy this when 7-day re-signing becomes the thing that annoys you most.** Best value per unit of hassle removed. |
| **Paid program + TestFlight** | $99/year (same) | Medium — App Store Connect setup, builds must be uploaded and pass review for external testing | Up to **10,000 external** and **100 internal** testers, 30 devices each. Apple's TestFlight page does **not** state the build-expiry period, so I am not quoting the number I have heard — verify it in App Store Connect Help before relying on it | Overkill for one phone. Worth it only when you want other people testing. |
| **Borrow a Mac** | $0 | Medium — one-off Xcode install, ~15 GB | Only works when you have the Mac; no good for routine iteration | Useful once, to confirm an Xcode build and signing work. Not a pipeline. |
| **Rented cloud Mac** | **MacStadium from $109/month** (cheapest Mac mini). MacinCloud's pages would not load for me (404 and 403) — **check macincloud.com in a browser yourself; I will not quote a price I could not verify** | Medium | Monthly cost dwarfs the $99/year developer account | **Don't.** Strictly worse than paying Apple $99 unless you need a persistent Mac for other reasons. |
| **Rewrite for Android / cross-platform** | $0–$25 (Google Play one-off, if publishing) | **Very high** — rewriting BLE + Spotify auth + the image pipeline | Throws away working Swift; Flutter/React Native BLE stacks are their own source of pain | **No.** Your Swift code is the most mature part of the project. Rewriting to dodge a $99 fee is a bad trade. |

**My recommendation for you:** stay on **GitHub Actions + Sideloadly** while you are fixing bugs —
it is free and already working. The moment re-signing every 7 days starts interrupting you, pay the
**$99**. Skip TestFlight, cloud Macs and any rewrite. Borrow a Mac once if you get the chance,
purely to sanity-check signing.

Sources: [Apple Developer Program ($99, Enterprise $299)](https://developer.apple.com/programs/) ·
[personal team limits — 7-day profile expiry, 3 apps per device, 3 devices](https://developer.apple.com/support/compare-memberships/) ·
[TestFlight tester counts](https://developer.apple.com/testflight/) ·
[GitHub Actions runner pricing](https://docs.github.com/en/billing/reference/actions-runner-pricing) ·
[GitHub Actions billing — free for public repos](https://docs.github.com/en/billing/managing-billing-for-your-products/about-billing-for-github-actions) ·
[MacStadium pricing](https://www.macstadium.com/pricing) ·
[AltStore](https://altstore.io) ·
[Sideloadly](https://sideloadly.io)

---

## 5. Where you can test what

| Environment | What it genuinely covers |
|---|---|
| **Windows alone** | Firmware compiles (`pio run`); reading/refactoring Swift; `python ios/gen_xcodeproj.py`; the Python prototype scripts' logic. **Not** Swift compilation. |
| **iOS Simulator** (needs a Mac — you have none) | That the app builds, launches, and that layout/SwiftUI changes look right. **BLE does not work** in the Simulator, so none of findings 2–4 are testable there. |
| **ESP32 + serial monitor** (broken-screen board) | Boot, SD card mount and cache index build, BLE connect/disconnect, MTU negotiation, header parse and chunk progress, cache hit/miss decisions, all telemetry lines, and the brightness write arriving (finding 1). Everything the firmware *says* it is doing. |
| **Real phone + working display** | Anything visual: the skip artifact (finding 2), transition correctness and speed (finding 9), art resize jump (finding 5), safe-area layout (finding 6), colours (finding 7), end-to-end latency, backlight actually changing. |
| **CI (GitHub Actions)** | Both targets compile on every push — the iOS build is the *only* compile check you have for Swift. It cannot test behaviour: no BLE, no display, no Spotify account. |

**Plainly: without your hardware I cannot verify a single behavioural claim in this report.** Every
finding above is read from source code. Findings 1, 10, 12 and the "not a bug" item are
code-reading facts I am confident in; findings 2, 3 and 4 are mechanisms I traced but whose
real-world symptoms only your board can confirm.

---

## 6. Where the process can be fixed

In priority order:

1. **CI does not fail on Swift warnings or run any tests** — `.github/workflows/build.yml` builds
   and packages, nothing more. There are zero tests in the repo (`test/` holds only a README). Your
   only safety net is "it compiled". Free to fix.
2. **The iOS build is unsigned, so every install is a manual Sideloadly session.** Free to improve
   partly (artifact naming, a release on tag); fully fixed only by the $99 account.
3. **The Xcode project is generated but not verified in CI** — if you add a Swift file and forget
   `python ios/gen_xcodeproj.py`, the cloud build silently compiles without it. A CI step that
   regenerates and fails on a diff would catch this. Free.
4. **No firmware test path at all.** The cache-key, CRC and filename-parsing functions are pure
   logic that could be unit-tested on the host via PlatformIO's native environment, with no board
   attached. Free, and it would have caught a truncation bug like the one you suspected.
5. **`platformio.ini` hardcodes `COM3`** for both upload and monitor, so the config is wrong on any
   other machine or port. Free.
6. **Protocol doc drift is manual** (finding 10 is live proof). Free to fix by convention; nothing
   enforces it.

Only item 2's full fix costs money ($99/year). Everything else is effort, not cash.

---

## 7. Future-proofing notes (do not start these)

- **Pins are already `#define`d** (`src/main.cpp:19-30`) — good. But they sit in the middle of the
  main file; a separate `include/board_config.h` would make a new PCB a one-file change.
- **The display size is hardcoded in the driver constructor**: `Arduino_ST7789(bus, TFT_RST, 0,
  true, 240, 240, 0, 0)` at `src/main.cpp:46` uses literal `240`s while `DISPLAY_WIDTH`/
  `DISPLAY_HEIGHT` are defined right above at `:32-33` and not used there.
- **240/115,200 is duplicated across three places in two languages** with no shared source of
  truth: `src/main.cpp:32-34`, `BLEManager.swift:90` (`imagePayloadBytes`), and
  `ImageProcessor.swift:8-9` (`targetW`/`targetH`). A new screen size means finding all three plus
  the protocol doc. A size field already negotiated over BLE would remove the coupling entirely.
- **The driver class is named directly** (`Arduino_ST7789`), and `Arduino_ESP32SPI` is constructed
  with `FSPI` and 80 MHz inline at `:45`. A different controller means editing this line and
  anything that assumes ST7789 quirks — note the `IPS=true` colour-inversion flag and the gamma
  notes in `resources/`.
- **All 17 transitions call `gfx->` directly**, so they are welded to this driver. A thin
  "draw these rows" interface would let both the transitions and a future screen move independently.

---

## 8. Recommended next 5 steps

Each is one sitting, and each ends with something you can check on the board.

1. **Fix the brightness channel** (finding 1) — one line in `src/main.cpp:385`. Verify: slider
   moves, backlight changes, serial still prints the value.
2. **Make the firmware refuse a new frame until the old one is finished** (finding 2) — the real
   bug, and the one most likely to explain your artifact. Verify with test 6 above, including the
   replay-from-cache check.
3. **Fix the two BLE wait races** (findings 3 and 4) — add the generation guard the other three
   paths already use, and make `awaitWriteWindow` re-check the flag after storing its continuation.
   Verify: 20 rapid skips with no spurious timeouts.
4. **Fix the art resize and the safe area** (findings 5 and 6) — constrain the art's frame
   independently of its siblings, and scope `ignoresSafeArea` to the top edge. Verify by eye on the
   phone, portrait, with and without the debug strip.
5. **Add the two free CI guards** (process items 1 and 3) — fail the build on Swift warnings, and
   regenerate the Xcode project in CI to catch a forgotten `gen_xcodeproj.py`. Verify: a deliberate
   warning turns the build red.

Steps 2 and 3 touch the app/firmware boundary together. They do not change the wire protocol, so
`docs/BLE_PROTOCOL.md` would not need a version bump — but I would tell you before touching it.

---

## 9. Questions — four answered, three still open

### Answered since the first draft

**1. Board model — settled.** You confirmed the
[Waveshare ESP32-S3-LCD-1.3](https://www.waveshare.com/product/esp32-related/boards-kits/esp32-s3/esp32-s3-lcd-1.3.htm).
From Waveshare's own pages: ESP32-S3R8, 16 MB flash, 8 MB PSRAM, 240×240, and it **has a TF card
slot** — all consistent with `platformio.ini` and the firmware. Two things worth knowing:

- The product page says the controller is **ST7789V2**, while the wiki links an **ST7789VW**
  datasheet and your `resources/` notes say ST7789VW. The firmware constructs a generic
  `Arduino_ST7789` with `IPS=true`, which works for both, so nothing is broken — but if you ever
  chase a colour or gamma oddity, that ambiguity is where to start.
- **The board has a QMI8658 six-axis IMU**, and Waveshare's factory demo turns the backlight off
  when the board is stood upright. That is not in your firmware at all, and it is a genuinely nice
  feature for a keychain — tilt to sleep. Noting it, not proposing it.

**I did get the schematic open.** The PDF's text is Flate-compressed, so the fetch could not read
it, but decompressing the streams locally worked. What it shows:

- The LCD is a 12-pin FPC (`TFT1`, labelled `LCD-240x240`): `LEDK`, `LEDA`, `VDD`, `D/C`, `CS`,
  `SCL`, `SDA`, `RES`. Four-wire SPI, matching the firmware's use.
- **The backlight net is literally named `BL_PWM`, and it is switched by a transistor (`Q5`,
  MMBT3904).** PWM dimming is designed into the board. **This settles finding 1: the brightness
  bug is purely a software fault, and fixing that one line should give you working dimming.**
- The SD card has its own nets (`SD_CS`, `SD_MOSI`, `SD_MISO`, `SD_CLK`) separate from the LCD's —
  a second SPI bus, which is what the firmware assumes.
- Module confirmed as `U3 ESP32-S3R8`.

**All ten pin defines are verified correct** against Waveshare's GPIO table, which you supplied:

| `src/main.cpp` | Value | Waveshare net | |
|---|---|---|---|
| `TFT_BL` | 20 | `BL_PWM` | ✓ |
| `TFT_RST` | 42 | `RES` | ✓ |
| `TFT_DC` | 38 | `DC` | ✓ |
| `TFT_CS` | 39 | `CS` | ✓ |
| `TFT_MOSI` | 41 | `MOSI` | ✓ |
| `TFT_SCLK` | 40 | `CLK` | ✓ |
| `SD_CS` | 17 | `SD_CS` | ✓ |
| `SD_MISO` | 16 | `SD_MISO` | ✓ |
| `SD_MOSI` | 18 | `SD_MOSI` | ✓ |
| `SD_CLK` | 21 | `SD_CLK` | ✓ |

**One small thing the table exposes.** `src/main.cpp:45` constructs the LCD bus as
`Arduino_ESP32SPI(TFT_DC, TFT_CS, TFT_SCLK, TFT_MOSI, 1 /* MISO */, FSPI, ...)` — it claims
**GPIO1** as the bus's MISO line. The LCD is write-only 4-wire SPI and has no MISO at all, and
Waveshare's table shows GPIO1 as a free pin broken out to the headers. So the firmware is silently
reserving a header pin it never reads. Harmless today; it would bite you the first time you wire
something to GPIO1. Passing `GFX_NOT_DEFINED` instead would release it.

**Four hardware features on this board that the firmware ignores entirely** (GPIOs now confirmed):

1. **`VBAT_ADC` on GPIO6** — battery-voltage sense. Worth knowing because `docs/BLE_PROTOCOL.md`'s
   roadmap lists a BLE Battery Service as "requires hardware". **The hardware is already there**,
   and `TODO_SWIFT.md` has "buy a new battery" as an open item.
2. **A WS2812B addressable RGB LED on GPIO15** — unused.
3. **The QMI8658 IMU** — `IMU_SDA` GPIO47, `IMU_SCL` GPIO48, interrupts on GPIO46/GPIO45. Unused.
   Waveshare's factory demo blanks the backlight when the board stands upright; tilt-to-sleep is a
   natural fit for a keychain.
4. **`RST_Control` on GPIO19** — unused.

None of these are bugs, and I am not proposing work on them — but they change what is cheap later.

**2. Toolchain — settled.** PlatformIO with the Arduino framework, core **2.0.17**, verified from
the installed package (`framework-arduinoespressif32` 3.20017). There are no `.ino` files anywhere
in the repo, so nothing suggests you ever used the Arduino IDE. One real consequence: with
`framework = arduino`, **`sdkconfig.defaults` is largely ignored** — PlatformIO uses prebuilt
Arduino libraries, so the PSRAM, BLE and stack-size settings in that file are not what is actually
applied. The settings that *do* take effect are the `build_flags` and `board_build.*` keys in
`platformio.ini`. The file is misleading and worth either deleting or commenting as inert.

**3. Pinning the core — yes, and here is why it is urgent.** `platform = espressif32` is unpinned,
so the next time PlatformIO resolves it you could land on core 3.x, where `ledcWrite`'s first
argument becomes a **pin** instead of a channel. That would silently make the current buggy line
correct and my recommended fix wrong — the worst kind of version drift. Pinning to the version you
have today removes that trap. I did not edit `platformio.ini`, since you asked me not to touch
existing files.

**5. The UI spec — found.** Not in the repo or its git history, but it is at
`C:\Users\Zyan\Downloads\SpotifyDisplay_UI_Spec.md`. I have read it and rewritten finding 7 against
the real document. It should be moved into the repo (`docs/`) so it is versioned with the code —
but that is a new file, so it needs your say-so. Note its section 5 depends on a draft
`ContentView.swift` "from an earlier chat", which I cannot retrieve.

### Still only you can answer

**4. iPhone model and iOS version?** Needed for the Developer Mode steps. Partly self-answering:
your deployment target is iOS 16 (`Package.swift`), and `ContentView.swift:146` uses the
single-parameter `onChange(of:)` form that iOS 17 deprecated — so the CI build on `macos-15` is
almost certainly emitting that warning today. Your device version does not change that; it only
decides the sideloading steps.

**6. Has the broken-screen board's backlight survived?** Decides whether test 4 fully or only
partly confirms finding 1.

**7. Does the cache-corruption theory match what you have seen?** The key question: have you ever
seen a *stable* wrong or mangled image for one particular album — the same bad image every time you
play it — as opposed to a brief flash? A yes promotes finding 2 from "likely" to "confirmed" and
makes it unambiguously the first thing to fix.

---

## 10. Design review: current iOS UI

Reviewed `ContentView.swift` against Apple's Human Interface Guidelines. Code review only — I have
no screenshots and no device, so this covers structure, hierarchy, contrast arithmetic and copy,
not how it actually feels in the hand.

**Overall: Needs work.** The bones are sound — correct tap targets, a sensible top-to-bottom
hierarchy, debug detail already hidden behind a toggle. What holds it back is that the visual
language has no system: six accent colours appear with no rule governing them, and state is
signalled by colour alone. There is no thesis yet; it reads as a functional test harness that grew
a layout, which is exactly the instinct behind wanting to redo it.

### Critical

**C1 · Connection state is conveyed by colour alone, and is invisible to VoiceOver.**
`StatusDot` (`ContentView.swift:202-216`) renders `active ? Color.green : Color.white.opacity(0.15)`
with the label text identical in both states. Someone who cannot distinguish the dot, or who uses
a screen reader, has no way to know whether the display is connected — the app's single most
important piece of status.
> `accessibility.md › Design`: "Convey information with more than color alone… Offer visual
> indicators, like distinct shapes or icons, in addition to color."

*Fix:* give the dot a shape difference (filled vs hollow ring), and add
`.accessibilityLabel("Display connected")` / `"Display not connected"` to the `HStack`.

**C2 · The redesign spec inherits the same flaw.** The spec's live strip encodes cache-hit versus
fresh-download as full-opacity white versus 25 % white, with "Color only, no text". That is
opacity rather than hue, so it is not a colour-blindness problem — but it is still a single visual
channel with no accessible equivalent. Worth fixing in the spec *before* it is built: the strip can
stay purely visual on screen as long as it carries an `.accessibilityLabel` and
`.accessibilityValue` describing the last transfer.

### Improvements

**I1 · Six accent colours, no system. (High)** `.cyan`, `.green`, `.purple`, `.orange` appear at
`:56`, `:61`, `:75`, `:107`, and `DebugStrip.liveColor()` (`:260-272`) maps phases to four more.
Nothing says what each colour *means*; cyan is "cache" in one place and "BLE" in another. The
monochrome spec fixes this by removing the problem entirely, which is the right call.

**I2 · Fixed 11 pt type that ignores Dynamic Type. (High)** `DebugStrip` uses
`.font(.system(size: 11, design: .monospaced))` (`:367`). 11 pt is exactly Apple's floor, and
because it is a fixed size it does not grow when the user enlarges text.
> `accessibility.md › Text`: iOS default 17 pt, **minimum 11 pt**.

*Fix:* `.font(.system(.caption2, design: .monospaced))`, or `size:11, relativeTo: .caption2`, so it
scales.

**I3 · Every colour is hard-coded, which blocks the spec's Appearance picker. (High)** The UI is
built from `.white.opacity(…)` and `Color.black` throughout, which only works because
`.preferredColorScheme(.dark)` is pinned at `:152`. The spec asks for a Dark/Light/System picker —
drop one in today and every label turns white-on-white.
> `dark-mode.md › Dark Mode`: "Avoid using hard-coded color values or colors that don't adapt."

*Fix:* move to semantic colours (`.primary`, `.secondary`) before adding the picker, not after.

**I4 · The Appearance picker itself is contrary to the HIG. (Medium — a real trade-off, your call)**
> `dark-mode.md › Dark Mode`: "**Avoid offering an app-specific appearance setting.** An
> app-specific appearance mode option creates more work for people… they may think your app is
> broken because it doesn't respond to their systemwide appearance choice."

But the same page allows the opposite: *"In rare cases, consider using only a dark appearance… for
an app that supports immersive media viewing."* This app is album art on black — that exemption
fits it well. My recommendation: **drop the picker from the spec and stay permanently dark.** It is
both more defensible and less work than making every colour adaptive.

**I5 · Sign-in gives no reason. (Medium)** The unauthenticated state is the bare string
`"Not signed in"` (`:47`).
> `managing-accounts.md › Managing accounts`: "Explain the benefits of creating an account… Display
> this message in your sign-in view."

*Fix:* one line — what connecting Spotify does and that no password is stored.

**I6 · `onChange(of:)` uses the deprecated iOS 16 signature. (Low)** `:146`. Fine at runtime,
noisy at build time on the iOS 18 SDK that CI uses.

### Craft notes

**The current look is a known default. (High)** Near-black plus a bright accent is one of the three
house styles that generated interfaces fall into, and this has four accents rather than one. There
is no element you would remember afterwards.

**The spec's instinct is right, and the strip is the signature.** Monochrome plus one 2 px strip
under the art is a genuine point of view: the only live feedback on the screen is a hairline that
mirrors the hardware. That is specific to *this* product — an app whose whole job is to feed a
physical display. Build around it.

**Remove one accessory.** The bottom bar currently carries two status dots, a rate-limit warning, a
cache count and a gear. The spec already cuts this to one line, which is the right instinct — but
the two dots and the count say overlapping things. One line of plain text, as the spec has it, is
enough.

**One caution for Figma.** The spec wants the background derived from blurred album art. Every
contrast figure below assumes pure black; the moment the background becomes a light album cover,
`.white.opacity(0.6)` text can fall under 4.5:1. Fix it with a scrim of fixed opacity over the blur
so text contrast stops depending on the artwork.

### What works

- **Tap targets are already right.** 44×44 on the skip buttons, 52×52 on play/pause, 44×44 on the
  gear with `.contentShape(Rectangle())` so the whole area is tappable
  (`accessibility.md › Controls`: iOS default **44×44 pt**). Keep this through the redesign.
- **Contrast on black passes comfortably.** `.white.opacity(0.6)` = `#999999` on `#000000` is
  **7.4:1**, and the dimmest text, `.opacity(0.55)` = `#8C8C8C`, is **6.2:1** — both clear of the
  4.5:1 floor (`accessibility.md › Text`).
- **Debug detail is already opt-in and off by default**, which is what the spec asks for. Only the
  storage key needs renaming.
- **The gear button already has `.accessibilityLabel("Settings")`.** Apply that habit to the status
  dots and the live strip.

---

## 11. Spotify sign-in and token handling

You asked me to make sure this is in order. **Mostly it is — this is the best-built part of the
app.** What is right, then four things to fix.

### Correct, and worth not breaking

- **PKCE done properly.** `codeVerifier()` (`SpotifyManager.swift:858`) takes 32 bytes from
  `SecRandomCopyBytes` — a cryptographic RNG, not `random()` — and base64url-encodes it to 43
  characters, inside RFC 7636's 43–128 range. The challenge is SHA-256 with
  `code_challenge_method=S256` (`:119`).
- **No client secret on the device**, which is correct for a public client.
- **`ASWebAuthenticationSession`** (`:137`) is the right API. Spotify's credentials are typed into
  Safari's own sheet, never a view this app controls.
- **Keychain storage is well chosen.** `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
  (`KeychainHelper.swift:16`) means the refresh token survives a reboot once unlocked — so
  background refresh works — but never syncs to iCloud and never leaves the device.
- **Rotating refresh tokens are handled.** Spotify issues a *new* refresh token on each PKCE
  refresh, and `:845-847` saves it. Missing this is the single most common cause of "randomly
  signed out" in Spotify PKCE apps, and it is handled.
- **Both refresh paths exist**: proactive, 60 s before expiry (`:749-757`), and reactive on a 401
  with one retry (`:741-746`).
- **Scopes are minimal** — `user-read-currently-playing` and `user-modify-playback-state`, exactly
  what the app uses.

### A1 · Two refreshes can race and invalidate each other — `app`, highest value here

`SpotifyManager` is `@MainActor`, but `await` lets other work interleave at suspension points.
While `refreshAccessToken` is suspended on the network call, `accessExpiry` has not yet been
updated — so a second caller reaching `ensureAccessTokenFresh` still sees an expired token and
starts a **second refresh with the same refresh token**. Because Spotify rotates refresh tokens,
the first response invalidates the token the second request is using; the loser gets
`invalid_grant`, and whichever finishes last overwrites the Keychain. Reachable when the poll loop
and the BLE `onReadyCallback` resync (`:278-283`) land together — i.e. **at reconnect**, which is
exactly when you would blame Bluetooth.

*Fix:* hold the in-flight refresh in a single `Task` and have later callers await that same task.

### A2 · "Session expired — sign in again" is shown for network failures — `app`

`restoreSession()` (`:261-271`) catches *every* error and sets that message. A refresh attempt with
no Wi-Fi throws, so launching the app offline tells you your session died when it did not. The
token is still in the Keychain and still valid.

*Fix:* only treat HTTP 400 `invalid_grant` as a dead session; on network or 5xx errors keep the
token and retry.

### A3 · Spotify's error text is thrown away — `app`

`exchangeCode` and `refreshAccessToken` (`:809`, `:836`) turn any non-2xx into a bare
`authFailed`, discarding the `{"error_description": …}` body. That is why diagnosing sign-in
problems needs the README's troubleshooting section — the app knows why it failed and does not say.

### A4 · Keychain writes fail silently — `app`

`KeychainHelper.save` (`:9-19`) ignores `SecItemAdd`'s `OSStatus`. If the write fails, the refresh
token is not stored, and you find out one launch later with no explanation.

### A5 · No `state` parameter — `app`, low risk, worth adding

The authorize request (`:116-121`) omits `state`, which Spotify's PKCE guide recommends for CSRF
protection. The real exposure here is small: the callback is delivered to the
`ASWebAuthenticationSession` that started it rather than through a general URL handler, so an
attacker cannot inject a code by getting the app to open a crafted link. Add it for correctness,
not urgency.

**None of A1–A5 touch the BLE protocol**, and none require a Spotify dashboard change.

---

## 12. Colour, dithering and gamma

Three stages decide what you actually see: the iOS colour grade, the RGB565 quantise-and-dither,
and the panel's gamma registers. **The headline: two of those three are independently pushing for
"more punch", neither aware of the other, and the quantiser has an arithmetic bug.**

Everything in C1–C2 below is provable from the code without hardware. C3–C5 need your eyes.

### C1 · The quantiser truncates instead of rounding — `app`, fix this first

`ImageProcessor.swift:163-165`:

```swift
let r5 = Int(UInt16(oldR) >> 3)     // 0-255 → 0-31 by truncation
```

Shifting right by 3 throws away the low bits, so every channel rounds **down**. The dequantisation
table it is compared against is correct (`dequantR[v] = v * 255 / 31`), so the error fed into the
dither is systematically biased positive:

| Input | Truncated | Displays as | Error |
|---|---|---|---|
| 8 | 1 | 8.2 | −0.2 |
| 15 | 1 | 8.2 | **+6.8** |
| 23 | 2 | 16.5 | **+6.5** |
| 250 | 31 | 255 | −5.0 |

Error should straddle zero in roughly ±4. Instead it runs about −0.5 to +7, averaging near +3.
Two consequences: the diffused error is **twice the size it needs to be**, which shows up as
visible dither texture rather than clean blending; and because Atkinson deliberately discards 25 %
of the error, a consistently positive bias means that discarded portion is always *brightness being
thrown away*. The image is quietly darker and noisier than it should be.

*Fix — round instead:*

```swift
let r5 = Int((oldR * 31.0 / 255.0).rounded())
let g6 = Int((oldG * 63.0 / 255.0).rounded())
let b5 = Int((oldB * 31.0 / 255.0).rounded())
```

This is the single highest-value change in the whole image path, and it costs nothing at runtime.

I suspect it is also *why* the grade pushes gamma to 0.85 and brightness to +0.01 — compensating
at stage one for a darkening introduced at stage two. Once rounding is in, that compensation is
probably over-correcting and should be re-tuned.

### C2 · The black-lift and highlight-clip are undone two filters later — `app`

`applyGrading` (`:70-104`) runs in this order: clamp to [0.03, 0.96] → gamma 0.85 → vibrance 0.25
→ **saturation 1.30, contrast 1.22**.

`CIColorControls` contrast pivots around 0.5, so the clamped ceiling of 0.96 comes back out as
`0.5 + (0.46 × 1.22) = 1.06` → clipped to pure white, and the 0.03 floor goes to `−0.07` → clipped
to pure black. **The clamp is completely undone by the filter that runs after it.** The comment
says it exists because "TFT panels have poor black levels, so crushed shadows look muddy" — a
correct instinct, defeated by ordering.

*Fix:* move the `CIColorClamp` to the **end** of the chain, after contrast and saturation.

### C3 · You are boosting twice — `both`

| Stage | What it does |
|---|---|
| iOS grade | gamma 0.85, vibrance +0.25, saturation 1.30, contrast 1.22 |
| Panel gamma | `main.cpp:1105-1106`, "tuned for slightly more punch/saturation" |

Compared against your own reference values in `resources/waveshare_esp32s3_lcd_gamma.md`, the
firmware's curve is lifted across the whole low and mid range:

| Entry | Reference | `main.cpp` |
|---|---|---|
| V1P | `0x04` | `0x06` |
| V2P | `0x0D` | `0x10` |
| V4P | `0x11` | `0x14` |
| V6P | `0x13` | `0x16` |
| V13P | `0x2B` | `0x30` |

So the panel is already brightening midtones before the app's gamma 0.85 brightens them again.
Stacked saturation (1.30 × vibrance × a punchier panel curve) is what drives deep reds and blues
into the gamut edge, where 5-bit red and blue have nothing left to resolve — detail in a saturated
cover collapses into flat blocks.

The code comment admits these values were never validated: *"to be fine-tuned on hardware"*.

**There is also a subtler cost.** Dithering works by spatial averaging — two adjacent levels blend
in your eye to the value in between. That only holds if the display's response between those two
levels is close to linear. A steep, hand-lifted gamma curve bends that response, so the dither
averages to the *wrong* value. **Aggressive panel gamma and dithering actively fight each other.**

*Recommendation:* pick one place to do the look. Put the panel back to the reference curve so it
reproduces sRGB honestly, and keep all the artistic adjustment on the phone, where you have floats,
a GPU and the ability to iterate without reflashing.

### C4 · No serpentine scan — `app`, medium

Every row dithers left-to-right (`:156-158`), so error always travels the same direction and
collects into faint diagonal "worming" in smooth gradients — skies, gradient album covers. Atkinson
hides this better than Floyd–Steinberg, but it is still there. Alternating direction on odd rows is
a few lines.

### C5 · Atkinson versus Floyd–Steinberg is a real choice, not a bug — `app`

Atkinson diffuses only 6/8 of the error. That is why it looks crisp and contrasty — it is the
classic Mac look — but it **clips both ends**: highlights blow out and shadows block up faster than
with full diffusion. On 240×240 album art at arm's length, crispness is arguably the right call,
and I would keep it. But it is worth knowing the trade, and it compounds with C1 and C3.

Note the docs disagree with themselves here: `resources/waveshare_esp32s3_lcd_gamma.md` recommends
Floyd–Steinberg in linear light, `main.cpp:1732` claims the phone does Floyd–Steinberg, and the
phone actually does Atkinson in sRGB. Worth settling the story.

### On dithering in sRGB rather than linear light

Your reference doc says to linearise, dither, then re-encode. The code dithers directly on
sRGB-encoded values. **I would leave this alone.** RGB565's quantisation grid is uniform in the
*encoded* domain, so diffusing encoded error matches where the precision is actually lost, and sRGB
is roughly perceptually uniform so the error lands where the eye weighs it evenly. Linear-light
dithering is defensible but would concentrate precision in highlights you cannot see on a 1.3"
panel. This is the one place the code is right and the doc is wrong.

### Suggested order

1. **C1** (rounding) — unambiguous, no judgement needed.
2. **C2** (clamp ordering) — restores the intent that is already in the code.
3. Re-shoot a reference album cover, then **C3**: revert the panel gamma to the reference values and
   re-tune the grade on the phone against that known baseline.
4. **C4** if gradients still show worming.

**Do not do these in the same flash as the brightness fix.** Brightness changes how every colour
reads; if both land together you cannot tell which change caused what. Verify brightness first,
then treat colour as its own pass with before/after photos of the same album.

---

## 13. Where dithering belongs, and is the pipeline worth reworking

### Dither on the phone. Keep it there.

This is already the right call, for four reasons that all point the same way:

1. **The wire format is RGB565 either way.** Dithering does not change the payload — 115,200 bytes
   go over BLE regardless. You pay nothing to dither before sending.
2. **The cache stores post-dither bytes**, so a cache hit is a straight SD→screen blit with zero
   CPU work on a 240 MHz MCU. Dithering on-device would mean either re-dithering on every cache hit
   (slower hits, the thing you most want fast) or caching the dithered result anyway — which is
   what you already do.
3. **The phone has floats, a GPU and Core Image.** The ESP32 has none of that to spare, and
   `loop()` is already the single owner of draw, SD and transition work.
4. **Iterating costs a rebuild, not a reflash.** Given the colour work in section 12 needs several
   rounds of look-and-adjust, this matters more than it sounds.

**One consequence nobody has written down: the cache is keyed on the album, not on the pipeline.**
Change the grade, the dither or the quantiser and every already-cached image keeps the *old* look
forever, while new ones get the new one — so you would be comparing two pipelines on one screen and
drawing wrong conclusions. There is already a `#define CACHE_KEY_VERSION 1` (`src/main.cpp:35`) for
exactly this. **Bump it whenever the image pipeline changes**, so old entries miss and refill.
Stale `v1_*.bin` files are not auto-deleted, so follow with a Clear cache from the app to reclaim
the space.

### Is the pipeline efficient? Mostly yes — and it is not your bottleneck

The dither loop itself is genuinely well written: unsafe pointers, precomputed dequantisation LUTs,
inlined neighbour writes, an early-out when error is zero. Leave it alone.

**Before optimising anything, read your own instrumentation.** `TransferLogEntry` already records
`downloadMs`, `convertMs` and `uploadMs` separately, and `DebugStrip` prints them as `dl`, `cv` and
`ble` (`ContentView.swift:330-336`). Turn on Settings → Debug info and compare. My strong
expectation is that `ble` dominates `cv` by an order of magnitude — 115,200 bytes over BLE is
seconds, the conversion is milliseconds. **If so, every hour spent optimising the image path buys
nothing**, and the honest answer is: do not rework it.

Two cheap wins if you want them anyway:

- **One rasterisation too many.** `convertToRGB565` calls `ciContext.createCGImage(...)`
  (`:60`) and then `packRGB565LittleEndian` immediately redraws that CGImage into a raw buffer via
  `CGContext.draw` (`:135`). That is two full 240×240 rasterisations. `CIContext.render(_:toBitmap:
  rowBytes:bounds:format:colorSpace:)` writes straight into the byte buffer and removes the
  intermediate image entirely. Should be pixel-identical with the same format and colour space, but
  worth one visual check.
- **The UInt8→Float conversion loop** (`:115-121`) is 57,600 iterations of bounds-checked array
  subscripting. `vDSP_vfltu8` does it in one call, or it could fold into the dither loop.

Both are pure performance, no visual change — so unlike section 12's fixes, they are safe to land
without disturbing the brightness test.

### The architectural fork, if transfers are the problem

If `ble` really is the bottleneck, the only large win is sending less data, and that forces a real
trade-off: **dithering and compression are mutually exclusive.**

- Sending 240×240 JPEG instead of raw RGB565 would cut the payload from 115,200 bytes to roughly
  10–20 KB — a 6–10× transfer reduction. The decoder already exists in your dependency tree; the
  GFX library ships `ImgViewerJpeg_JPEGDEC` and `ImgViewerJpeg_ESP32_JPEG` examples.
- But JPEG is a lossy frequency-domain codec and **dithering is high-frequency noise by
  construction** — JPEG would smear exactly the pattern you spent effort producing. You would have
  to drop dithering and accept plain RGB888→RGB565 truncation on-device, which is visibly worse
  banding, or dither on the ESP32, which is slow.

So the current design already made the choice: **quality over first-play speed**, with the cache
making every repeat play fast regardless. For a device that mostly replays your own library, that
is the right trade. I would not change it — but it is the lever to pull if first-play latency ever
becomes the complaint.
