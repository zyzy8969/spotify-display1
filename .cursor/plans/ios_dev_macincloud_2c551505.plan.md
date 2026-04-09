---
name: iOS dev MacinCloud
overview: Build and stabilize the iOS app first (MacinCloud + device BLE); GitHub, README, and recruiter demo materials come after the app works end-to-end. Optional battery BLE and firmware polish follow priorities below.
todos:
  - id: mac-workflow
    content: "Confirm MacinCloud plan: Xcode access, Apple ID/2FA, path to install on physical iPhone (USB vs TestFlight vs ad hoc)"
    status: pending
  - id: ble-baseline
    content: "Smoke-test existing SwiftPM app on device against current firmware; compare iOS write chunk size / speed with firmware MTU log"
    status: pending
  - id: dithering-decision
    content: "Choose iOS-side vs ESP32-side dithering; if iOS, update ImageProcessor + firmware draw path and document flash"
    status: pending
  - id: defer-protocol
    content: "Defer track-ID cache + custom BLE UUID until P2P requirements are fixed; then change firmware + iOS + Python in one release"
    status: pending
  - id: battery-telemetry
    content: "If hardware supports it: firmware ADC/voltage or fuel gauge → BLE (Battery Service or custom char); iOS UI + optional low-battery warning"
    status: pending
  - id: github-repo
    content: "After app is stable: create GitHub repo — README, LICENSE, .gitignore (.pio, venv, secrets), env example for Spotify; no credentials in git"
    status: completed
  - id: recruiter-poc
    content: "After GitHub: README PoC narrative (pitch, stack, limits), architecture sketch, 30–60s demo video or GIF, honest limitations"
    status: completed
---

# iOS development without a Mac + firmware notes

## What you already have

- **Firmware**: [src/main.cpp](../../src/main.cpp) — generic BLE service `0000ffe0-...`, MTU request `517`, cache files `/cache/XXYYZZWW.bin` from first **4** bytes of the **16-byte** key, progressive line draw while receiving, then **Floyd–Steinberg** + full redraw + save (cached files are already dithered).
- **Desktop reference**: [python/spotify_album_sender.py](../../python/spotify_album_sender.py) — same UUIDs, `CHUNK_SIZE = 512`, cache packet `0xDEADBEEF` + MD5(image URL).
- **iOS**: [SpotifyDisplay.swiftpm/Sources/SpotifyDisplay/BLEManager.swift](../../SpotifyDisplay.swiftpm/Sources/SpotifyDisplay/BLEManager.swift) — matches the above (512 default, **dynamic** `maximumWriteValueLength(for: .withoutResponse)`), filters peripherals by name **`Spotify Display`**, cache key = MD5 of URL ([ImageProcessor.swift](../../SpotifyDisplay.swiftpm/Sources/SpotifyDisplay/ImageProcessor.swift) outputs raw RGB565 truncate; **dithering is still only on the ESP32**).

There is **no battery reporting** in the firmware today; showing “device battery” in the app is **new work** (see below).

## Proof of concept (recruiters) vs scaling later

**PoC goal**: Show that you can ship an **end-to-end system** (mobile client, embedded firmware, third-party API, BLE protocol)—not that the product is production-complete.

**Phase A — App first (current priority)**

- Get **SpotifyDisplay** running on a **physical iPhone** (MacinCloud or any Mac): connect, poll playback, push art over BLE, handle errors and reconnects.
- Optional: **battery UI** on the app once firmware exposes it (or hide until then).
- Keep **code boundaries** clean while building (BLE, image pipeline, auth in separate types).

**Phase B — After the app works (GitHub + recruiter polish)**

- **GitHub public repo** with README: pitch, stack, how to run / hardware, **Current limitations**.
- **Short demo**: screen recording or GIF in README; TestFlight or device-only is fine for interviews.
- **Thin architecture diagram** (ASCII or Mermaid) in README when you publish.

**Executed (repo files):** root [README.md](../../README.md), [LICENSE](../../LICENSE), [python/env.example](../../python/env.example), [.gitignore](../../.gitignore) updates, [docs/BLE_PROTOCOL.md](../../docs/BLE_PROTOCOL.md), minimal white UI in `ContentView` / `SpotifyDisplayApp`. **You still record** the demo video and run `git init` / push to GitHub when ready.

**Defer until there is real traction**

- Dedicated **backend**, **OTA**, **subscription billing**, **Extended Streaming** / full compliance review.
- Hard **multi-tenant security** — use PKCE; never ship client secrets in app binaries.

**If the idea blows up—what “done right” tends to add**

1. Legal / platform (Spotify policy, Apple review, privacy policy if needed).
2. Identity & devices (cloud linking, pairing tokens).
3. Reliability (OTA, logging, factory tests).
4. Scale (rate limits, caching/CDN, support).
5. Team handoff: versioned BLE doc ([docs/BLE_PROTOCOL.md](../../docs/BLE_PROTOCOL.md)), semver for firmware + app.

## MacinCloud (and practical alternatives)

| Approach | Good for | Caveats |
|----------|-----------|---------|
| **MacinCloud (or similar rented Mac)** | Full Xcode, Simulator, archives, TestFlight | **BLE needs a physical iPhone**. |
| **GitHub Actions / other CI macOS** | Builds, tests | Device install still manual for BLE. |
| **Borrow a Mac short-term** | First device deploy | Same BLE reality. |

**Signing**: Swift Package in Xcode + team + bundle id; ensure **Info.plist** Bluetooth usage and Spotify redirect URL.

## Display device battery level (new)

Hardware + firmware + BLE Battery Service or custom characteristic; iOS discovers and shows % with fallback. Not implemented.

## Open-source on GitHub

**Timing**: App-first is fine; repo scaffolding is now in tree—push when you create the remote.

## Firmware / app decisions (prioritized)

1. Move dithering to iOS (UX) — deferred.
2. Atkinson on ESP32 — deferred.
3. Cache filename = track ID — defer with P2P.
4. Private BLE UUID — optional.
5. MTU — verify on device vs Serial log.

## Suggested execution order

1. **MacinCloud (or Mac) + Xcode** — run [SpotifyDisplay.swiftpm](../../SpotifyDisplay.swiftpm) on **physical iPhone**; **ble-baseline**.
2. **App completeness** — further UI/UX as needed.
3. **`git init` + GitHub remote** — push this repo.
4. **Demo video** — link from README “Recruiter demo” section.
5. **Battery** / **dithering** / protocol when prioritized.
