"""
Web Color Tuner - Adjust ESP32 display settings in your browser
Simple sliders, instant preview, way easier than CLI
"""

from flask import Flask, render_template_string, request, jsonify
import requests
import io
import struct
import asyncio
from PIL import Image
from wand.image import Image as WandImage
from bleak import BleakClient, BleakScanner
import threading
import time
import os
from dotenv import load_dotenv
import spotipy
from spotipy.oauth2 import SpotifyOAuth

# Load environment variables
load_dotenv()

app = Flask(__name__)

# ==================================================
# CONFIGURATION
# ==================================================

# BLE Configuration
BLE_NAME = "Spotify Display"
IMAGE_CHAR_UUID = "0000ffe3-0000-1000-8000-00805f9b34fb"
MESSAGE_CHAR_UUID = "0000ffe4-0000-1000-8000-00805f9b34fb"
STATUS_CHAR_UUID = "0000ffe1-0000-1000-8000-00805f9b34fb"

CHUNK_SIZE = 512
DISPLAY_WIDTH = 240
DISPLAY_HEIGHT = 240

# Spotify Configuration
CLIENT_ID = os.getenv("SPOTIFY_CLIENT_ID")
CLIENT_SECRET = os.getenv("SPOTIFY_CLIENT_SECRET")
REDIRECT_URI = "http://localhost:8888/callback"
REFRESH_TOKEN = os.getenv("SPOTIFY_REFRESH_TOKEN")

# Test images (fallback if no Spotify track)
TEST_IMAGES = [
    "https://i.scdn.co/image/ab67616d0000b273e8b066f70c206551210d902b",  # Bohemian Rhapsody
    "https://i.scdn.co/image/ab67616d0000b2734ce8b4e42588bf18182a1ad2",  # The Beatles
    "https://i.scdn.co/image/ab67616d0000b273ba5db46f4b838ef6027e6f96",  # Daft Punk
]

# Global state
ble_client = None
ble_connected = False
spotify_client = None
cached_images = {}
last_settings = None
current_track_info = None

# ==================================================
# IMAGE PROCESSING
# ==================================================

def convert_to_rgb565(img):
    width, height = img.size
    rgb565_data = bytearray(width * height * 2)
    pixels = img.load()
    idx = 0
    for y in range(height):
        for x in range(width):
            r, g, b = pixels[x, y]
            r5 = (r >> 3) & 0x1F
            g6 = (g >> 2) & 0x3F
            b5 = (b >> 3) & 0x1F
            rgb565 = (r5 << 11) | (g6 << 5) | b5
            rgb565_data[idx] = rgb565 & 0xFF
            rgb565_data[idx + 1] = (rgb565 >> 8) & 0xFF
            idx += 2
    return bytes(rgb565_data)

def process_image(image_url, saturation, brightness, contrast, level_black, level_white, level_gamma):
    # Download/cache image
    if image_url not in cached_images:
        response = requests.get(image_url, timeout=10)
        cached_images[image_url] = response.content

    image_data = cached_images[image_url]

    with WandImage(blob=image_data) as wand_img:
        wand_img.resize(DISPLAY_WIDTH, DISPLAY_HEIGHT, filter='lanczos')
        wand_img.level(black=level_black, white=level_white, gamma=level_gamma)
        wand_img.modulate(brightness=brightness, saturation=saturation, hue=100)
        wand_img.brightness_contrast(brightness=0, contrast=contrast)

        pil_bytes = io.BytesIO()
        wand_img.format = 'png'
        wand_img.save(file=pil_bytes)
        pil_bytes.seek(0)
        img = Image.open(pil_bytes)

    if img.mode != 'RGB':
        img = img.convert('RGB')

    return convert_to_rgb565(img)

# ==================================================
# BLE FUNCTIONS
# ==================================================

async def connect_ble():
    global ble_client, ble_connected

    devices = await BleakScanner.discover(timeout=5.0)
    for device in devices:
        if device.name == BLE_NAME:
            ble_client = BleakClient(device.address)
            await ble_client.connect()

            # Simple notification handler
            def handler(sender, data):
                pass

            await ble_client.start_notify(IMAGE_CHAR_UUID, handler)
            await ble_client.start_notify(MESSAGE_CHAR_UUID, handler)
            await ble_client.start_notify(STATUS_CHAR_UUID, handler)

            ble_connected = True
            print("✓ Connected to ESP32")
            return True

    print("✗ ESP32 not found")
    return False

async def send_to_display(rgb565_data):
    if not ble_client or not ble_connected:
        return False

    try:
        # Send size header
        size_packet = struct.pack('<I', len(rgb565_data))
        await ble_client.write_gatt_char(IMAGE_CHAR_UUID, size_packet)
        await asyncio.sleep(0.01)

        # Send data
        for i in range(0, len(rgb565_data), CHUNK_SIZE):
            chunk = rgb565_data[i:i+CHUNK_SIZE]
            await ble_client.write_gatt_char(IMAGE_CHAR_UUID, chunk, response=False)
            await asyncio.sleep(0.002)

        await asyncio.sleep(0.5)  # Wait for ESP32 to process
        return True
    except Exception as e:
        print(f"Send error: {e}")
        return False

def send_sync(rgb565_data):
    """Synchronous wrapper for async send"""
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    result = loop.run_until_complete(send_to_display(rgb565_data))
    loop.close()
    return result

# ==================================================
# SPOTIFY FUNCTIONS
# ==================================================

def init_spotify():
    """Initialize Spotify client"""
    global spotify_client

    if not all([CLIENT_ID, CLIENT_SECRET, REFRESH_TOKEN]):
        print("⚠ Spotify credentials not found - using test images only")
        return False

    try:
        sp_oauth = SpotifyOAuth(
            client_id=CLIENT_ID,
            client_secret=CLIENT_SECRET,
            redirect_uri=REDIRECT_URI,
            scope="user-read-playback-state user-read-currently-playing"
        )

        token_info = sp_oauth.refresh_access_token(REFRESH_TOKEN)
        access_token = token_info['access_token']
        spotify_client = spotipy.Spotify(auth=access_token)

        print("✓ Connected to Spotify")
        return True
    except Exception as e:
        print(f"⚠ Spotify connection failed: {e}")
        return False

def get_current_track():
    """Get currently playing track info"""
    global current_track_info

    if not spotify_client:
        return None

    try:
        current = spotify_client.current_playback()

        if current is None or not current.get('item'):
            return None

        track = current['item']
        images = track['album']['images']

        if not images:
            return None

        # Get largest image
        largest_image = images[0]

        current_track_info = {
            'track_name': track['name'],
            'artist': ', '.join([artist['name'] for artist in track['artists']]),
            'album': track['album']['name'],
            'image_url': largest_image['url'],
            'image_size': f"{largest_image.get('width', '?')}x{largest_image.get('height', '?')}"
        }

        return current_track_info

    except Exception as e:
        print(f"Error getting current track: {e}")
        return None

# ==================================================
# WEB ROUTES
# ==================================================

HTML_TEMPLATE = """
<!DOCTYPE html>
<html>
<head>
    <title>ESP32 Color Tuner</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Arial, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            padding: 20px;
            color: #fff;
        }
        .container {
            max-width: 800px;
            margin: 0 auto;
            background: rgba(255,255,255,0.95);
            border-radius: 20px;
            padding: 30px;
            box-shadow: 0 20px 60px rgba(0,0,0,0.3);
            color: #333;
        }
        h1 {
            text-align: center;
            margin-bottom: 10px;
            color: #667eea;
            font-size: 2em;
        }
        .status {
            text-align: center;
            padding: 10px;
            border-radius: 10px;
            margin-bottom: 20px;
            font-weight: bold;
        }
        .status.connected { background: #10b981; color: white; }
        .status.disconnected { background: #ef4444; color: white; }

        .control-group {
            margin-bottom: 25px;
            background: #f9fafb;
            padding: 20px;
            border-radius: 10px;
        }
        .control-group h3 {
            margin-bottom: 15px;
            color: #667eea;
            font-size: 1.1em;
        }
        .slider-container {
            margin-bottom: 20px;
        }
        .slider-label {
            display: flex;
            justify-content: space-between;
            margin-bottom: 8px;
            font-weight: 500;
        }
        .slider-value {
            color: #667eea;
            font-weight: bold;
            min-width: 50px;
            text-align: right;
        }
        input[type="range"] {
            width: 100%;
            height: 8px;
            border-radius: 5px;
            background: #d1d5db;
            outline: none;
            -webkit-appearance: none;
        }
        input[type="range"]::-webkit-slider-thumb {
            -webkit-appearance: none;
            appearance: none;
            width: 20px;
            height: 20px;
            border-radius: 50%;
            background: #667eea;
            cursor: pointer;
        }
        input[type="range"]::-moz-range-thumb {
            width: 20px;
            height: 20px;
            border-radius: 50%;
            background: #667eea;
            cursor: pointer;
            border: none;
        }

        .button-group {
            display: flex;
            gap: 10px;
            margin-top: 20px;
        }
        button {
            flex: 1;
            padding: 15px;
            border: none;
            border-radius: 10px;
            font-size: 1em;
            font-weight: bold;
            cursor: pointer;
            transition: transform 0.1s, box-shadow 0.1s;
        }
        button:active {
            transform: scale(0.98);
        }
        .btn-send {
            background: #10b981;
            color: white;
        }
        .btn-send:hover {
            background: #059669;
        }
        .btn-reset {
            background: #ef4444;
            color: white;
        }
        .btn-reset:hover {
            background: #dc2626;
        }
        .btn-preset {
            background: #8b5cf6;
            color: white;
        }
        .btn-preset:hover {
            background: #7c3aed;
        }

        .presets {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
            gap: 10px;
            margin-top: 15px;
        }
        .preset-btn {
            padding: 12px;
            background: #f3f4f6;
            border: 2px solid #d1d5db;
            color: #333;
        }
        .preset-btn:hover {
            border-color: #667eea;
            background: #e0e7ff;
        }

        .image-selector {
            margin-bottom: 20px;
        }
        .image-selector label {
            display: block;
            margin-bottom: 8px;
            font-weight: 500;
        }
        .image-selector select {
            width: 100%;
            padding: 10px;
            border-radius: 8px;
            border: 2px solid #d1d5db;
            font-size: 1em;
        }

        #sendStatus {
            margin-top: 15px;
            padding: 10px;
            border-radius: 8px;
            text-align: center;
            font-weight: bold;
            display: none;
        }
        #sendStatus.success {
            background: #d1fae5;
            color: #065f46;
            display: block;
        }
        #sendStatus.error {
            background: #fee2e2;
            color: #991b1b;
            display: block;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>🎨 ESP32 Color Tuner</h1>
        <div class="status {{ 'connected' if connected else 'disconnected' }}">
            {{ 'Connected to ESP32' if connected else 'ESP32 Not Connected' }}
        </div>

        <div class="control-group" id="currentTrackSection" style="background: linear-gradient(135deg, #1DB954 0%, #1ed760 100%); color: white; margin-bottom: 20px;">
            <h3 style="color: white;">🎵 Currently Playing</h3>
            <div id="currentTrackInfo" style="padding: 10px; background: rgba(0,0,0,0.2); border-radius: 8px; margin-bottom: 10px;">
                <div style="font-size: 0.9em; opacity: 0.8;">Loading...</div>
            </div>
        </div>

        <div class="control-group">
            <h3>Color Settings</h3>

            <div class="slider-container">
                <div class="slider-label">
                    <span>Saturation</span>
                    <span class="slider-value" id="saturation-val">125</span>
                </div>
                <input type="range" id="saturation" min="0" max="200" value="125" step="5">
            </div>

            <div class="slider-container">
                <div class="slider-label">
                    <span>Brightness</span>
                    <span class="slider-value" id="brightness-val">90</span>
                </div>
                <input type="range" id="brightness" min="50" max="150" value="90" step="5">
            </div>

            <div class="slider-container">
                <div class="slider-label">
                    <span>Contrast</span>
                    <span class="slider-value" id="contrast-val">23</span>
                </div>
                <input type="range" id="contrast" min="0" max="50" value="23" step="1">
            </div>
        </div>

        <div class="control-group">
            <h3>Level Adjustment</h3>

            <div class="slider-container">
                <div class="slider-label">
                    <span>Black Point</span>
                    <span class="slider-value" id="level_black-val">0.03</span>
                </div>
                <input type="range" id="level_black" min="0" max="0.5" value="0.03" step="0.01">
            </div>

            <div class="slider-container">
                <div class="slider-label">
                    <span>White Point</span>
                    <span class="slider-value" id="level_white-val">0.90</span>
                </div>
                <input type="range" id="level_white" min="0.5" max="1.0" value="0.90" step="0.01">
            </div>

            <div class="slider-container">
                <div class="slider-label">
                    <span>Gamma</span>
                    <span class="slider-value" id="level_gamma-val">0.93</span>
                </div>
                <input type="range" id="level_gamma" min="0.5" max="2.0" value="0.93" step="0.01">
            </div>
        </div>

        <div class="control-group">
            <h3>Quick Presets</h3>
            <div class="presets">
                <button class="preset-btn" onclick="loadPreset('vibrant')">Vibrant</button>
                <button class="preset-btn" onclick="loadPreset('natural')">Natural</button>
                <button class="preset-btn" onclick="loadPreset('punchy')">Punchy</button>
                <button class="preset-btn" onclick="loadPreset('pastel')">Pastel</button>
            </div>
        </div>

        <div class="button-group">
            <button class="btn-send" onclick="sendToDisplay()">📤 Send Current Song to Display</button>
            <button class="btn-reset" onclick="resetToDefaults()">🔄 Reset Settings</button>
        </div>

        <div id="sendStatus"></div>
    </div>

    <script>
        const presets = {
            vibrant: { saturation: 125, brightness: 90, contrast: 23, level_black: 0.03, level_white: 0.90, level_gamma: 0.93 },
            natural: { saturation: 100, brightness: 100, contrast: 5, level_black: 0.05, level_white: 0.95, level_gamma: 1.0 },
            punchy: { saturation: 150, brightness: 95, contrast: 15, level_black: 0.15, level_white: 0.85, level_gamma: 1.2 },
            pastel: { saturation: 80, brightness: 110, contrast: 3, level_black: 0.05, level_white: 0.98, level_gamma: 0.9 }
        };

        let currentTrackData = null;

        // Update value displays
        document.querySelectorAll('input[type="range"]').forEach(slider => {
            slider.addEventListener('input', (e) => {
                document.getElementById(e.target.id + '-val').textContent = e.target.value;
            });
        });

        function loadPreset(name) {
            const preset = presets[name];
            for (let key in preset) {
                const slider = document.getElementById(key);
                if (slider) {
                    slider.value = preset[key];
                    document.getElementById(key + '-val').textContent = preset[key];
                }
            }
        }

        function resetToDefaults() {
            loadPreset('vibrant');
        }

        function loadCurrentTrack() {
            fetch('/current_track')
                .then(res => res.json())
                .then(data => {
                    const trackInfo = document.getElementById('currentTrackInfo');
                    if (data.success && data.track) {
                        currentTrackData = data.track;
                        trackInfo.innerHTML = `
                            <div style="font-weight: bold; font-size: 1.1em; margin-bottom: 4px;">${data.track.track_name}</div>
                            <div style="font-size: 0.9em; opacity: 0.9;">${data.track.artist}</div>
                            <div style="font-size: 0.8em; opacity: 0.7; margin-top: 4px;">${data.track.album} • ${data.track.image_size}</div>
                        `;
                    } else {
                        trackInfo.innerHTML = '<div style="font-size: 0.9em; opacity: 0.8;">No song playing - play something on Spotify!</div>';
                        currentTrackData = null;
                    }
                })
                .catch(err => {
                    console.error('Error loading track:', err);
                });
        }

        function sendToDisplay() {
            if (!currentTrackData) {
                alert('No song currently playing on Spotify - play something first!');
                return;
            }

            const settings = {
                use_current_track: true,
                saturation: parseInt(document.getElementById('saturation').value),
                brightness: parseInt(document.getElementById('brightness').value),
                contrast: parseInt(document.getElementById('contrast').value),
                level_black: parseFloat(document.getElementById('level_black').value),
                level_white: parseFloat(document.getElementById('level_white').value),
                level_gamma: parseFloat(document.getElementById('level_gamma').value)
            };

            const status = document.getElementById('sendStatus');
            status.textContent = 'Processing and sending...';
            status.className = '';
            status.style.display = 'block';

            fetch('/send', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(settings)
            })
            .then(res => res.json())
            .then(data => {
                if (data.success) {
                    status.textContent = '✓ Sent to display!';
                    status.className = 'success';
                    setTimeout(() => { status.style.display = 'none'; }, 2000);
                } else {
                    status.textContent = '✗ Send failed: ' + (data.error || 'Unknown error');
                    status.className = 'error';
                }
            })
            .catch(err => {
                status.textContent = '✗ Error: ' + err;
                status.className = 'error';
            });
        }

        // Load current track on page load and refresh every 10 seconds
        window.addEventListener('load', () => {
            loadCurrentTrack();
            setInterval(loadCurrentTrack, 10000);
        });
    </script>
</body>
</html>
"""

@app.route('/')
def index():
    return render_template_string(HTML_TEMPLATE, connected=ble_connected)

@app.route('/current_track')
def current_track():
    """Get currently playing Spotify track"""
    track_info = get_current_track()
    if track_info:
        return jsonify({'success': True, 'track': track_info})
    else:
        return jsonify({'success': False, 'error': 'No track playing'})

@app.route('/send', methods=['POST'])
def send():
    data = request.json

    try:
        # Get current Spotify track
        track_info = get_current_track()
        if not track_info:
            return jsonify({'success': False, 'error': 'No track currently playing'})

        image_url = track_info['image_url']

        # Process image
        rgb565 = process_image(
            image_url,
            data['saturation'],
            data['brightness'],
            data['contrast'],
            data['level_black'],
            data['level_white'],
            data['level_gamma']
        )

        # Send to ESP32
        success = send_sync(rgb565)

        return jsonify({'success': success})

    except Exception as e:
        return jsonify({'success': False, 'error': str(e)})

# ==================================================
# STARTUP
# ==================================================

def start_server():
    print("\n" + "="*60)
    print("ESP32 Web Color Tuner")
    print("="*60)

    # Connect to Spotify
    print("\nConnecting to Spotify...")
    spotify_ok = init_spotify()

    # Connect to ESP32
    print("\nConnecting to ESP32...")
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    connected = loop.run_until_complete(connect_ble())

    if connected:
        print("\n✓ Ready!")
        print("\nOpen your browser to:")
        print("  → http://localhost:5000")
        if spotify_ok:
            print("\nUsage:")
            print("  1. Play a song on Spotify")
            print("  2. Adjust color sliders")
            print("  3. Click 'Send Current Song to Display'\n")
        else:
            print("\n✗ Spotify not available - won't be able to send images\n")
        app.run(debug=False, host='0.0.0.0', port=5000)
    else:
        print("\n✗ Could not connect to ESP32")
        print("Make sure it's powered on and advertising")

if __name__ == '__main__':
    start_server()
