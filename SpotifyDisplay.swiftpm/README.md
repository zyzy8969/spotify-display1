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

1. Double-click **`Package.swift`** or open the `SpotifyDisplay.swiftpm` folder in Xcode.
2. Select the **SpotifyDisplay** scheme and an **iPhone** run destination.
3. Set your **Signing** team for the generated app target if Xcode creates one, or use **File → New → Project → App** and add this package as a local dependency if the package alone does not produce a runnable `.app` on your Xcode version.

## First run

1. **Settings** → enter **Spotify Client ID** → **Save** → **Sign in with Spotify** (PKCE; no client secret stored on device).
2. Grant **Bluetooth** when prompted.
3. Power the ESP32; it should advertise as **Spotify Display**.
4. Play music; the app polls about once per second and sends art after a short debounce. The **cached file count** is shown **only in this iPhone app** (the ESP32 does not draw that number on its screen; it only reports it over BLE).

## Layout

- `Sources/SpotifyDisplay/` — app sources (`@main`, BLE, Spotify PKCE, image pipeline)
- `Sources/SpotifyDisplay/Resources/Info.plist` — URL scheme `spotifydisplay`, Bluetooth usage string

## Behavior notes

- **Token refresh**: Access tokens are refreshed proactively before expiry (not only after HTTP 401).
- **BLE throughput**: Image chunks use **write-without-response** when the characteristic supports it, with the CoreBluetooth write queue (`peripheralIsReadyToSendWriteWithoutResponse`).
- **Paused playback**: When nothing is playing, the “now playing” line clears; the display may still show the last art until the next track.

## Troubleshooting

- **Redirect URI mismatch**: In the [Spotify Dashboard](https://developer.spotify.com/dashboard), add `spotifydisplay://callback` under Redirect URIs.
- **Currently playing**: Requires Spotify **user** auth scope (`user-read-currently-playing`); some account/API limits apply.
- **No cache count**: Flash firmware that handles stats magic `0xC0FFEEE1` on the cache characteristic (see `main.cpp`).
