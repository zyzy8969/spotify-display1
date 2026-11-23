# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

## Users

Right now the only user is the owner, who builds the app, sideloads it and uses it daily with their own keychain. The product is meant to become something other people buy: a keychain plus this app. Design decisions should hold up for a first-time owner who has never seen the code, not only for the builder.

The main job is **glance and confirm**. The app mostly runs in the background, polling Spotify and sending covers to the keychain. When someone opens it, it is usually for a few seconds, to check that the keychain is connected and showing the right cover. Deeper tools (transition picker, stats, photo upload, settings) exist but are secondary.

## Product Purpose

The product is a digital keychain. The Spotify cover is the main thing it shows; your own photos (available now) and GIFs (planned) are secondary. The app's job is to connect to the keychain over Bluetooth and send it those images. Concretely, the app turns what you are playing on Spotify into album art on a small physical display you carry: an ESP32-S3 keychain with a 240x240 screen. The app signs in to Spotify, follows the current track, prepares the cover for the keychain and sends it over Bluetooth Low Energy. The keychain draws it with an animated transition and caches it, so a repeat play shows up almost instantly.

Success means the keychain shows the right cover, whole, soon after the song changes, without the user having to open the app. When they do open it, the app should tell them at a glance whether everything is working.

## Positioning

The app is the companion to a piece of hardware, not a music player. It never competes with Spotify's own app. It exists to keep a physical object in sync with what is playing, and to show the state of that link honestly: connected or not, cached or sent fresh, drawn or still in progress.

## Operating Context

- Mostly runs in the background, using iOS Bluetooth state restoration and background time. Users open it briefly, often on the move.
- Signs in to Spotify with PKCE (no client secret; redirect `spotifydisplay://callback`). The sign-in screen tells the user their password stays with Spotify.
- Pairs with one keychain, found by its Bluetooth name `Spotify Display`. It talks to the keychain over the versioned protocol in `docs/BLE_PROTOCOL.md`.
- Distribution today: an unsigned `.ipa` built by GitHub Actions (macOS runner) and sideloaded from Windows. The owner has no Mac.

## Capabilities and Constraints

- Now Playing screen: current cover and track, the keychain's connection and send state, a live strip under the art, and playback controls.
- Sending: about 1 Hz now-playing poll; checks the keychain's cache by key first; full transfer only on a miss (DEFLATE-compressed when the keychain supports it); prefetches the next 5 queued covers.
- The keychain owns the picture: nothing appears on it until a frame has arrived complete. The app has to wait for the keychain to confirm before it can say a cover was drawn (for example the `CACHE_RENDERED` reply), never show success early.
- Settings: brightness, theme, clearing the keychain's cache, sign out, Client ID override, and a "show stats" toggle that adds General and Live stats pages.
- Also: a transition picker, a live mirror of the board, and photo upload to the keychain.
- Three themes the user can pick: Crayon (default), Quiet and Serif. New themes are added as theme tokens, not new screens.
- Hardware and Bluetooth behaviour can only be checked on the physical device. The app cannot be compiled on the owner's machine.
- Open decisions: how the app is distributed to buyers (App Store, TestFlight or something else), pricing, and how a new owner first pairs their keychain (onboarding).

## Brand Commitments

- Name in use: "Spotify Display". README states the project is not affiliated with Spotify AB. **Open decision:** whether a product sold to other people can keep "Spotify" in its name.
- How the app speaks depends on the theme. Crayon writes in lowercase and plays with words, calling the keychain "your keychain" and saying "empty it". Quiet and Serif write in plain sentence case ("Clear display cache"). All wording lives in `ThemeCopy.swift`.
- The app is the "keychain" companion: user-facing copy refers to the device as a keychain or display, never as an ESP32 or a board.

## Evidence on Hand

- The working hardware and the app, used by the owner every day.
- A webcam rig aimed at the keychain, used to check that covers are actually drawn.
- On-device test script: `docs/VALIDATION_CHECKLIST.md`.
- None yet: buyers, testimonials, reviews, pricing, sales figures or App Store listing. Future work must not invent any of these.

## Product Principles

1. **The keychain is the product; the app gets out of the way.** It should run in the background without fuss, and the screen you open should answer "is it working?" in a glance.
2. **Never claim what the keychain hasn't confirmed.** Connection, cached versus fresh, and "drawn" come from the keychain's own replies. Never guess optimistically.
3. **Built for someone who isn't the builder.** As this heads toward other buyers, choose plain status and recovery over debug detail. Detailed stats stay behind a toggle.
4. **Speed you can feel.** Covers should reach the keychain soon after the track changes. Whatever helps them get there faster (caching, prefetch, compression) is the core value, not an extra.
