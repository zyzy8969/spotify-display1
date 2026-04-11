# Spotify Display — iOS app (Swift)

**Monorepo:** `spotify-display1` — **full layout and limitations:** [../README.md](../README.md)

**BLE contract (shared with firmware + Python):** [../docs/BLE_PROTOCOL.md](../docs/BLE_PROTOCOL.md)

Native iOS sender for the ESP32 **Spotify Display** firmware: BLE GATT matches [`main.cpp`](../src/main.cpp) (same protocol as [`python/spotify_album_sender.py`](../python/spotify_album_sender.py)).

## Requirements

- **Mac with Xcode 15+** (build and run on a physical iPhone; BLE does not work in all simulator setups)
- **iOS 16+**
- Spotify app: register redirect URI **`spotifydisplay://callback`** (exact) for your Client ID
- ESP32 flashed with current firmware (includes `CACHE_COUNT` support if you use “Refresh cache count”)

## Open in Xcode

**Recommended:** open **[`../ios/SpotifyDisplay.xcodeproj`](../ios/SpotifyDisplay.xcodeproj)** — a normal iOS app project that references these sources. See **[`../ios/README.md`](../ios/README.md)** (Personal Team, `spotifydisplay://callback`, regenerating the project with `python3 ios/gen_xcodeproj.py` after file changes).

**Alternative:** double-click **`Package.swift`** or open the `SpotifyDisplay.swiftpm` folder in Xcode, select a scheme/run destination, and set **Signing** if Xcode exposes a runnable target for your Xcode version.

## First run

1. Set **`SpotifyClientID`** in `Sources/SpotifyDisplay/Resources/Info.plist` to your [dashboard](https://developer.spotify.com/dashboard) Client ID, **or** use **Settings → Client ID override** (optional). Then **Sign in with Spotify** (PKCE; no client secret on device).
2. Grant **Bluetooth** when prompted.
3. Power the ESP32; it should advertise as **Spotify Display**.
4. Play music; the app polls about once per second and sends art after a short debounce. The **cached file count** is shown **only in this iPhone app** (the ESP32 does not draw that number on its screen; it only reports it over BLE).

## Layout

- `Sources/SpotifyDisplay/` — app sources (`@main`, BLE, Spotify PKCE, image pipeline)
- `Sources/SpotifyDisplay/Resources/Info.plist` — URL scheme `spotifydisplay`, Bluetooth usage string, optional **`SpotifyClientID`**

## Behavior notes

- **Token refresh**: Access tokens are refreshed proactively before expiry (not only after HTTP 401).
- **Spotify polling**: **Currently playing** is requested about **once per second** (good for skips). **HTTP 429** triggers a **cooldown** using **`Retry-After`** (capped) so the app does not keep calling the API while rate-limited.
- **BLE throughput**: Image chunks use **write-without-response** when the characteristic supports it, with the CoreBluetooth write queue (`peripheralIsReadyToSendWriteWithoutResponse`).
- **Paused playback**: When nothing is playing, the “now playing” line clears; the display may still show the last art until the next track.

## Troubleshooting

- **Redirect URI mismatch**: In the [Spotify Dashboard](https://developer.spotify.com/dashboard), add `spotifydisplay://callback` under Redirect URIs.
- **Currently playing**: Requires Spotify **user** auth scope (`user-read-currently-playing`); some account/API limits apply.
- **No cache count**: Flash firmware that handles stats magic `0xC0FFEEE1` on the cache characteristic (see `main.cpp`).
