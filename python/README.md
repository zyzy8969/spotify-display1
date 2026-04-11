# Python dev tools (archived)

These scripts were the **original development tools** for this project — used to prototype
BLE image sending, test color grading, and validate the ESP32 firmware before the iOS app existed.
They are kept for reference but are **not the active client**.

| Script | Purpose |
|--------|---------|
| `spotify_album_sender.py` | Desktop BLE + Spotify sender (original client, replaced by iOS app) |
| `color_test.py` | Send static test images to tune colors on the display |
| `live_color_editor.py` | Interactive color grading with live preview |
| `web_color_tuner.py` | Browser-based color parameter tuner |
| `test_esp32_connection.py` | BLE connection smoke test |
| `list_ports.py` | List available serial ports |

## Setup (if you want to run them)

```bash
cd python
python -m venv venv && source venv/bin/activate   # Windows: venv\Scripts\activate
pip install -r requirements.txt
cp env.example .env   # fill SPOTIFY_CLIENT_ID and SPOTIFY_CLIENT_SECRET
```

`.env` is gitignored — never commit credentials.
