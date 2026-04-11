# Spotify Display — Xcode project (iOS)

This folder contains a **generated** Xcode app project that compiles the same Swift sources as [`../SpotifyDisplay.swiftpm`](../SpotifyDisplay.swiftpm/) (files under `../SpotifyDisplay.swiftpm/Sources/SpotifyDisplay/`). Use it when you prefer a normal **`.xcodeproj`** workflow instead of opening the Swift package alone.

## Generate or refresh the project

From the **repository root**:

```bash
python3 ios/gen_xcodeproj.py
```

This writes:

- `ios/SpotifyDisplay.xcodeproj/project.pbxproj`
- `ios/SpotifyDisplay.xcodeproj/xcshareddata/xcschemes/SpotifyDisplay.xcscheme`

Run the script after adding or renaming Swift files under `SpotifyDisplay.swiftpm/Sources/SpotifyDisplay/`.

## Open in Xcode

1. Double-click **`SpotifyDisplay.xcodeproj`** (or **File → Open** and select it).
2. Select the **SpotifyDisplay** scheme and an **iPhone** run destination (BLE needs a **physical device**; the Simulator is enough only to verify the project compiles).
3. **Signing & Capabilities**: choose your **Personal Team** (Apple ID), set a **unique bundle identifier** (replace the placeholder `com.example.spotifydisplay` in the target’s **Build Settings** if needed).
4. In the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard), register redirect URI **`spotifydisplay://callback`** for your iOS client (PKCE; no client secret in the app).

### Spotify Client ID (no typing in the app by default)

- Set **`SpotifyClientID`** in [`SpotifyDisplay.swiftpm/Sources/SpotifyDisplay/Resources/Info.plist`](../SpotifyDisplay.swiftpm/Sources/SpotifyDisplay/Resources/Info.plist) to your dashboard app’s Client ID (edit the string value in Xcode). The app reads this at launch; PKCE is unchanged.
- Optional: **Settings → Client ID override** stores a per-device value in UserDefaults (wins over Info.plist when non-empty).

### Verification if music / Spotify data fails (BLE still works)

Bluetooth and Spotify use different paths. Check the on-screen **`pollStatus`** line and **`lastError`**:

1. Dashboard: same Spotify app as your Client ID; redirect URI exactly **`spotifydisplay://callback`**.
2. **Sign out** and **Sign in with Spotify** again after changing the dashboard or Client ID.
3. Play music on the **same** Spotify account you authorized; avoid private session while testing.
4. Interpret **`pollStatus`**: `Not authenticated` → Client ID / sign-in; `Nothing playing` → playback / account; `Spotify request failed` → see **`lastError`**; `Playing: …` → API OK (then look at BLE if the device has no art).

### Spotify Web API usage

- While monitoring, the app requests **currently playing** about **once per second** (responsive to track skips).
- If Spotify returns **HTTP 429**, the app reads **`Retry-After`** (seconds, capped) and **avoids further player requests** until that cooldown ends, so traffic stays within practical limits.

## Personal Team / no paid program

- You can install on your own devices for **about seven days** without the Apple Developer Program; renew by rebuilding/reinstalling.
- **TestFlight** and **App Store** distribution require a paid membership (out of scope for this PoC tier).

## Export compliance

`Info.plist` includes **`ITSAppUsesNonExemptEncryption` = false** (standard for apps that only use HTTPS/TLS). Adjust if you add custom crypto.

## Command-line build (optional)

With **Xcode.app** installed and selected (`xcode-select -s /Applications/Xcode.app/Contents/Developer`):

```bash
cd ios
xcodebuild -scheme SpotifyDisplay -destination 'generic/platform=iOS Simulator' build
```

Use a real **iPhone** destination for on-device BLE testing.

For **full-screen white** UI and **square album crop** (matches ESP32 aspect-fill), confirm on a **physical device**; the Simulator can still show slight differences around safe areas.
