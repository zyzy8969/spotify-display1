"""
Spotify Album Art Sender - Sends RGB565 images to ESP32 via Bluetooth LE
Optimized Mode: ImageMagick + RGB565 (truncation). Current ESP32 firmware expects phone-side Floyd–Steinberg (see iOS `ImageProcessor`); this script does not dither yet.
BLE Mode: Wireless transfer using Bluetooth Low Energy

Project: spotify-display1
Credentials: copy env.example to .env in this folder (never commit .env).
BLE contract: ../docs/BLE_PROTOCOL.md (must match src/main.cpp and iOS BLEManager).
"""

import spotipy
from spotipy.oauth2 import SpotifyOAuth
from PIL import Image
import requests
import time
import io
import struct
import os
from dotenv import load_dotenv
from wand.image import Image as WandImage  # High-quality Lanczos resizing
import hashlib
import asyncio
from bleak import BleakClient, BleakScanner
from bleak.exc import BleakError

# ==================================================
# SESSION STATISTICS TRACKING
# ==================================================

class SessionStats:
    """Track session performance metrics"""
    def __init__(self):
        self.start_time = time.time()
        self.tracks_played = 0
        self.cache_hits = 0
        self.cache_misses = 0
        self.total_transfer_time = 0
        self.total_data_transferred = 0
        self.tracks_history = []

    def add_track(self, track_name, artist, cache_hit, transfer_time=0, data_size=0):
        self.tracks_played += 1
        if cache_hit:
            self.cache_hits += 1
        else:
            self.cache_misses += 1
            self.total_transfer_time += transfer_time
            self.total_data_transferred += data_size

        self.tracks_history.append({
            'time': time.time(),
            'track': track_name,
            'artist': artist,
            'cache_hit': cache_hit
        })

    def print_summary(self):
        runtime = time.time() - self.start_time
        print("\n" + "="*60)
        print("📊 SESSION SUMMARY")
        print("="*60)
        print(f"Runtime: {runtime/60:.1f} minutes")
        print(f"Tracks played: {self.tracks_played}")

        if self.tracks_played > 0:
            cache_rate = self.cache_hits / self.tracks_played * 100
            print(f"Cache efficiency: {self.cache_hits}/{self.tracks_played} hits ({cache_rate:.1f}%)")

        if self.cache_misses > 0:
            avg_speed = (self.total_data_transferred / 1024) / self.total_transfer_time
            print(f"Data transferred: {self.total_data_transferred/1024:.1f} KB")
            print(f"Average speed: {avg_speed:.1f} KB/s")

        if self.tracks_history:
            print("\n🎵 Recently Played:")
            for track in self.tracks_history[-5:]:
                marker = "💾" if track['cache_hit'] else "⬇"
                print(f"  {marker} {track['track']} - {track['artist']}")

        print("="*60)

# ==================================================
# KEYBOARD INPUT HELPER
# ==================================================

def check_keyboard_input():
    """Non-blocking keyboard input check"""
    import sys

    try:
        if sys.platform == 'win32':
            import msvcrt
            if msvcrt.kbhit():
                return msvcrt.getch().decode('utf-8').lower()
        else:
            # Unix/Linux
            import select
            dr, dw, de = select.select([sys.stdin], [], [], 0)
            if dr:
                return sys.stdin.read(1).lower()
    except:
        pass
    return None

# Load environment variables
load_dotenv()

# Spotify credentials
CLIENT_ID = os.getenv("SPOTIFY_CLIENT_ID")
CLIENT_SECRET = os.getenv("SPOTIFY_CLIENT_SECRET")
REDIRECT_URI = os.getenv("SPOTIFY_REDIRECT_URI", "http://127.0.0.1:8888/callback")
REFRESH_TOKEN = os.getenv("SPOTIFY_REFRESH_TOKEN")

# Display settings
DISPLAY_WIDTH = 240
DISPLAY_HEIGHT = 240

# BLE UUIDs (must match ESP32)
SERVICE_UUID = "0000ffe0-0000-1000-8000-00805f9b34fb"
STATUS_CHAR_UUID = "0000ffe1-0000-1000-8000-00805f9b34fb"
CACHE_CHAR_UUID = "0000ffe2-0000-1000-8000-00805f9b34fb"
IMAGE_CHAR_UUID = "0000ffe3-0000-1000-8000-00805f9b34fb"
MESSAGE_CHAR_UUID = "0000ffe4-0000-1000-8000-00805f9b34fb"

# Transfer settings
CHUNK_SIZE = 512  # BLE: Reduced to prevent ESP32 BLE stack overflow
VERBOSE_LOGGING = False  # Set True for detailed logs, False for clean output

# === IMAGE PROCESSING SETTINGS (Optimized for Vibrant Display) ===

# Black/white level adjustment method
# Options: 'normalize', 'auto_level', 'sigmoidal', 'level', 'none'
LEVEL_METHOD = 'level'

# Level adjustment parameters (optimized for maximum vibrancy + deep blacks)
LEVEL_BLACK = 0.03      # Black point: Deep blacks without losing shadow detail
LEVEL_WHITE = 0.90      # White point: Brighter whites (clip brightest 10%)
LEVEL_GAMMA = 0.89    # Midtone gamma: Balanced for deep blacks + bright highlights

# Sigmoidal contrast parameters (only used if LEVEL_METHOD='sigmoidal')
SIGMOIDAL_STRENGTH = 3
SIGMOIDAL_MIDPOINT = 0.45

# Color enhancement (maximized for vibrant, non-washed-out colors)
SATURATION = 110        # High saturation for vibrant, punchy colors
BRIGHTNESS_ADJUST = 90  # Slightly reduced to prevent washout
CONTRAST = 19           # Higher contrast for deeper blacks and brighter highlights


def convert_to_rgb565(img):
    """
    Convert PIL image to RGB565 format using NumPy vectorization (10-50x faster).
    Truncation-only RGB565 (no Floyd–Steinberg). Match iOS/firmware contract in `docs/BLE_PROTOCOL.md`.
    """
    import numpy as np

    # Convert PIL image to numpy array
    img_array = np.array(img, dtype=np.uint8)

    # Extract RGB channels
    r = img_array[:, :, 0]
    g = img_array[:, :, 1]
    b = img_array[:, :, 2]

    # Quantize to RGB565 (vectorized operations - much faster than loops)
    r5 = (r >> 3).astype(np.uint16)
    g6 = (g >> 2).astype(np.uint16)
    b5 = (b >> 3).astype(np.uint16)

    # Pack into RGB565 format
    rgb565 = (r5 << 11) | (g6 << 5) | b5

    # Convert to little-endian bytes
    return rgb565.astype('<u2').tobytes()



def get_cache_key(url):
    """Generate 16-byte MD5 hash for ESP32 cache key"""
    return hashlib.md5(url.encode('utf-8')).digest()


def download_and_convert_image(url):
    """Download album art, process with ImageMagick, convert to RGB565"""
    if VERBOSE_LOGGING:
        print(f"  Downloading image from: {url[:50]}...")

    try:
        response = requests.get(url, timeout=10)
        response.raise_for_status()

        if not response.content:
            raise ValueError("Empty image data received")

    except Exception as e:
        raise Exception(f"Failed to download image: {e}")

    # === IMAGEMAGICK PROCESSING ===
    if VERBOSE_LOGGING:
        print(f"  Processing with ImageMagick...")

    with WandImage(blob=response.content) as wand_img:
        # Step 1: Resize with Lanczos filter (superior quality)
        wand_img.resize(DISPLAY_WIDTH, DISPLAY_HEIGHT, filter='lanczos')

        # Step 2: Fix washed out blacks/whites
        if LEVEL_METHOD == 'normalize':
            wand_img.normalize()
        elif LEVEL_METHOD == 'auto_level':
            wand_img.auto_level()
        elif LEVEL_METHOD == 'sigmoidal':
            wand_img.sigmoidal_contrast(sharpen=True, strength=SIGMOIDAL_STRENGTH, midpoint=SIGMOIDAL_MIDPOINT)
        elif LEVEL_METHOD == 'level':
            wand_img.level(black=LEVEL_BLACK, white=LEVEL_WHITE, gamma=LEVEL_GAMMA)

        # Step 3: Boost saturation/contrast
        wand_img.modulate(brightness=BRIGHTNESS_ADJUST, saturation=SATURATION, hue=100)
        wand_img.brightness_contrast(brightness=0, contrast=CONTRAST)

        # Convert ImageMagick -> PIL for RGB565 conversion
        pil_bytes = io.BytesIO()
        wand_img.format = 'png'
        wand_img.save(file=pil_bytes)
        pil_bytes.seek(0)
        img = Image.open(pil_bytes)

    # Ensure RGB mode
    if img.mode != 'RGB':
        img = img.convert('RGB')

    # === FAST RGB565 CONVERSION ===
    if VERBOSE_LOGGING:
        print(f"  Converting to RGB565 (truncation; firmware no longer dithers on BLE receive)...")

    rgb565_data = convert_to_rgb565(img)

    # Consolidated output
    if not VERBOSE_LOGGING:
        print(f"  Preparing image (download → ImageMagick → RGB565): {len(rgb565_data)} bytes")
    else:
        print(f"  ✓ Ready: {len(rgb565_data)} bytes")

    return rgb565_data


# ==================================================
# BLUETOOTH LE FUNCTIONS
# ==================================================

class BLEContext:
    """Manages BLE connection state and callbacks"""
    def __init__(self):
        self.ready_event = asyncio.Event()
        self.cache_response_event = asyncio.Event()
        self.transfer_complete_event = asyncio.Event()
        self.cached = False
        self.messages = []
        self.transition_name = None

    def reset_cache_check(self):
        """Reset cache check state"""
        self.cache_response_event.clear()
        self.cached = False
        self.transition_name = None

    def reset_transfer(self):
        """Reset transfer state"""
        self.transfer_complete_event.clear()


async def find_spotify_display():
    """Scan for ESP32 BLE device"""
    print("Scanning for 'Spotify Display' BLE device...")
    devices = await BleakScanner.discover(timeout=10.0)

    for device in devices:
        if device.name == "Spotify Display":
            print(f"✓ Found device: {device.name} ({device.address})")
            return device.address

    return None


async def connect_to_display(address):
    """Connect to ESP32 and wait for ready signal"""
    client = BleakClient(address)
    await client.connect()
    print(f"✓ Connected to {address}")

    # Create context for managing callbacks
    ctx = BLEContext()

    # Define all callbacks (these stay active for the entire connection)
    def status_callback(sender, data):
        if data[0] == 0x01:  # Ready signal
            print("✓ Device is READY")
            ctx.ready_event.set()

    def cache_callback(sender, data):
        ctx.cached = (data[0] == 0x01)  # 0x01 = CACHED, 0x00 = NEED
        ctx.cache_response_event.set()

    def image_callback(sender, data):
        if len(data) == 1 and data[0] == 0x01:  # SUCCESS
            ctx.transfer_complete_event.set()

    def message_callback(sender, data):
        message = data.decode('utf-8', errors='ignore')
        if message:
            if message == "SUCCESS":
                ctx.transfer_complete_event.set()
            elif message.startswith("TRANSITION:"):
                # Parse and store transition name for cache hit performance tracking
                ctx.transition_name = message.split(":", 1)[1]
                if VERBOSE_LOGGING:
                    print(f"  [DEBUG] Received transition: {ctx.transition_name}")
            elif message:
                print(f"  ESP32: {message}")
                ctx.messages.append(message)

    # Subscribe to ALL notifications ONCE
    await client.start_notify(STATUS_CHAR_UUID, status_callback)
    await client.start_notify(CACHE_CHAR_UUID, cache_callback)
    await client.start_notify(IMAGE_CHAR_UUID, image_callback)
    await client.start_notify(MESSAGE_CHAR_UUID, message_callback)

    # Give BLE stack time to complete subscription setup
    await asyncio.sleep(0.05)  # Optimized: 200ms → 50ms

    # Wait up to 5 seconds for ready signal
    try:
        await asyncio.wait_for(ctx.ready_event.wait(), timeout=5.0)
    except asyncio.TimeoutError:
        print("WARNING: Did not receive READY signal, proceeding anyway...")

    return client, ctx


async def check_cache_ble(client, ctx, image_url):
    """Check if image is cached on ESP32 via BLE"""
    # Reset cache check state
    ctx.reset_cache_check()

    # Prepare cache check packet: 4-byte magic + 16-byte MD5
    cache_key = get_cache_key(image_url)
    packet = struct.pack('<I', 0xDEADBEEF) + cache_key  # 20 bytes total

    # Write cache check
    if VERBOSE_LOGGING:
        print("  Sending cache check request...")

    cache_start = time.time()

    try:
        await client.write_gatt_char(CACHE_CHAR_UUID, packet)
        if VERBOSE_LOGGING:
            print("  ✓ Cache check request sent")
    except Exception as e:
        print(f"  ✗ Failed to send cache check: {e}")
        raise

    # Wait for response (up to 5 seconds)
    try:
        await asyncio.wait_for(ctx.cache_response_event.wait(), timeout=5.0)
    except asyncio.TimeoutError:
        print("  ERROR: Cache check timeout")
        return False

    if ctx.cached:
        # Wait a bit for TRANSITION message to arrive (sent before cache response)
        await asyncio.sleep(0.02)  # Optimized: 50ms → 20ms

        cache_time = time.time() - cache_start
        if VERBOSE_LOGGING:
            print(f"  [DEBUG] ctx.transition_name = {ctx.transition_name}")
        transition_info = f" (transition: {ctx.transition_name})" if ctx.transition_name else ""
        print(f"  ✓ Cache HIT - displayed in {cache_time:.2f}s{transition_info}")
        return True
    else:
        if VERBOSE_LOGGING:
            print("  Cache MISS - will send image")
        return False


async def send_image_ble(client, ctx, image_data):
    """Send image data over BLE"""
    # Reset transfer state
    ctx.reset_transfer()

    # Step 1: Send size header (4 bytes, little-endian)
    size_packet = struct.pack('<I', len(image_data))
    await client.write_gatt_char(IMAGE_CHAR_UUID, size_packet)
    if VERBOSE_LOGGING:
        print(f"  Sent size header: {len(image_data)} bytes")
    await asyncio.sleep(0.005)  # Optimized: 10ms → 5ms

    # Step 2: Send image data in chunks
    total_sent = 0
    start_time = time.time()

    for i in range(0, len(image_data), CHUNK_SIZE):
        chunk = image_data[i:i+CHUNK_SIZE]
        await client.write_gatt_char(IMAGE_CHAR_UUID, chunk, response=False)  # No response = faster
        total_sent += len(chunk)

        # Progress reporting with bar
        progress = (total_sent / len(image_data)) * 100

        if not VERBOSE_LOGGING:
            # Show progress bar
            bar_length = 20
            filled = int((total_sent / len(image_data)) * bar_length)
            bar = '█' * filled + '·' * (bar_length - filled)
            print(f"  Transfer: [{bar}] {progress:.0f}%", end='\r')
        else:
            # Verbose: show percentage updates
            if total_sent % 16384 == 0 or total_sent == len(image_data):
                print(f"  Progress: {progress:.1f}%", end='\r')

        # Small delay to prevent overwhelming ESP32
        await asyncio.sleep(0.001)  # Optimized: 2ms → 1ms inter-chunk delay

    # New line after progress
    print()

    if VERBOSE_LOGGING:
        print(f"  Sent {total_sent} bytes")

    # Wait for SUCCESS confirmation (up to 10 seconds)
    try:
        await asyncio.wait_for(ctx.transfer_complete_event.wait(), timeout=10.0)
        transfer_time = time.time() - start_time
        speed_kbps = (len(image_data) / 1024) / transfer_time
        print(f"  ✓ Complete: {transfer_time:.2f}s @ {speed_kbps:.1f} KB/s")
    except asyncio.TimeoutError:
        print("  ERROR: Transfer timeout")


# ==================================================
# PARALLEL DOWNLOAD TASK
# ==================================================

class DownloadTask:
    """Manages parallel download that can be cancelled on cache hit"""
    def __init__(self):
        self.task = None
        self.result = None
        self.error = None

    async def start_download(self, url):
        """Download and process in background thread"""
        try:
            self.result = await asyncio.to_thread(download_and_convert_image, url)
        except Exception as e:
            self.error = e

    def cancel(self):
        """Cancel download if still running"""
        if self.task and not self.task.done():
            self.task.cancel()

    async def get_result(self):
        """Wait for and return result"""
        if self.task:
            try:
                await self.task
            except asyncio.CancelledError:
                return None

        if self.error:
            raise self.error
        return self.result


async def process_track_parallel(client, ctx, image_url):
    """Process track with parallel cache check + download

    Returns:
        tuple: (success: bool, cache_hit: bool)
    """

    # Start both operations simultaneously
    download_task = DownloadTask()
    download_task.task = asyncio.create_task(download_task.start_download(image_url))

    # Cache check runs in parallel with download
    cache_hit = await check_cache_ble(client, ctx, image_url)

    if cache_hit:
        # Cancel download to save bandwidth/CPU
        download_task.cancel()
        return (True, True)  # success, cache_hit

    # Cache miss - wait for download (may already be done!)
    if not VERBOSE_LOGGING:
        print("  Cache MISS - preparing image...")

    rgb565_data = await download_task.get_result()

    if rgb565_data is None:
        print("  ✗ Download failed or cancelled")
        return (False, False)  # failure, cache_miss

    # Transfer to ESP32
    await send_image_ble(client, ctx, rgb565_data)
    return (True, False)  # success, cache_miss


async def main_async():
    """Main async function - BLE mode"""
    print("=" * 60)
    print("Spotify Album Art Sender (BLE MODE)")
    print("Optimized: ImageMagick + RGB565 (see BLE_PROTOCOL for dither expectations)")
    print("=" * 60)

    if not all([CLIENT_ID, CLIENT_SECRET, REFRESH_TOKEN]):
        print("\nERROR: Missing Spotify credentials!")
        return

    # Initialize session statistics
    stats = SessionStats()

    print("\n⌨  Press 'h' anytime for keyboard commands\n")

    # Find and connect to ESP32 via BLE
    address = await find_spotify_display()
    if not address:
        print("\nERROR: Could not find 'Spotify Display' BLE device!")
        print("Make sure ESP32 is powered on and advertising.")
        return

    client, ctx = await connect_to_display(address)
    if not client.is_connected:
        print("\nERROR: Could not connect to ESP32!")
        return

    sp_oauth = SpotifyOAuth(
        client_id=CLIENT_ID,
        client_secret=CLIENT_SECRET,
        redirect_uri=REDIRECT_URI,
        scope="user-read-currently-playing"
    )

    token_info = sp_oauth.refresh_access_token(REFRESH_TOKEN)
    sp = spotipy.Spotify(auth=token_info['access_token'])

    print("\nMonitoring Spotify... (Press Ctrl+C to stop)")
    print("=" * 60)

    last_track_id = None
    pending_track = None
    pending_time = None
    DEBOUNCE_DELAY = 0.5

    try:
        while True:
            # Check if BLE connection is still alive
            if not client.is_connected:
                print("\n⚠ BLE connection lost! Attempting to reconnect...")
                try:
                    # Try to reconnect
                    client, ctx = await connect_to_display(address)
                    print("✓ Reconnected successfully!")
                except Exception as e:
                    print(f"✗ Reconnection failed: {e}")
                    print("Retrying in 5 seconds...")
                    await asyncio.sleep(5)
                    continue

            try:
                current = sp.current_playback()

                if current is None or not current.get('item'):
                    await asyncio.sleep(5)
                    continue

                if current and current['item']:
                    track = current['item']
                    track_id = track['id']
                    is_playing = current['is_playing']

                    if track_id != last_track_id and is_playing:
                        if not pending_track or pending_track['id'] != track_id:
                            pending_track = track
                            pending_time = time.time()

                    if pending_track and pending_time:
                        if time.time() - pending_time >= DEBOUNCE_DELAY:
                            track_name = pending_track['name']
                            artist_name = pending_track['artists'][0]['name']
                            track_id = pending_track['id']

                            print(f"Now Playing: {track_name} - {artist_name}")

                            images = pending_track['album']['images']
                            if images:
                                image_url = images[0]['url']

                                try:
                                    # Parallel cache check + download for optimal performance
                                    print(f"  Processing album art: {images[0].get('width', '?')}x{images[0].get('height', '?')}")
                                    success, cache_hit = await process_track_parallel(client, ctx, image_url)

                                    if success:
                                        last_track_id = track_id
                                        # Track statistics
                                        stats.add_track(track_name, artist_name, cache_hit)
                                        print()
                                    else:
                                        print("  ✗ Failed to process track")
                                except BleakError as e:
                                    print(f"  ✗ BLE error: {e}")
                                    print("  Connection may have been lost, will retry on next track...")
                                    pending_track = None
                                    continue
                                except asyncio.TimeoutError:
                                    print("  ✗ BLE operation timed out")
                                    pending_track = None
                                    continue
                            else:
                                print("  No album art available")

                            pending_track = None
                            pending_time = None

            except spotipy.exceptions.SpotifyException as e:
                if "token expired" in str(e).lower():
                    print("Token expired, refreshing...")
                    token_info = sp_oauth.refresh_access_token(REFRESH_TOKEN)
                    sp = spotipy.Spotify(auth=token_info['access_token'])
                elif hasattr(e, 'http_status') and e.http_status == 429:
                    # Rate limited - use Retry-After header or default to 60s
                    retry_after = 60
                    if hasattr(e, 'headers') and e.headers and 'Retry-After' in e.headers:
                        retry_after = int(e.headers.get('Retry-After', 60))
                    print(f"⚠ Rate limited! Waiting {retry_after}s before retrying...")
                    await asyncio.sleep(retry_after)
                else:
                    print(f"Spotify error: {e}")

            except Exception as e:
                print(f"Error: {e}")
                pending_track = None

            # Check for keyboard commands
            key = check_keyboard_input()
            if key:
                if key == 's':
                    # Show statistics
                    stats.print_summary()

                elif key == 'v':
                    # Toggle verbose logging
                    global VERBOSE_LOGGING
                    VERBOSE_LOGGING = not VERBOSE_LOGGING
                    print(f"\n💬 Verbose logging: {'ON' if VERBOSE_LOGGING else 'OFF'}")

                elif key == 'r':
                    # Force refresh next track
                    last_track_id = None
                    print("\n↻ Will force refresh on next track change")

                elif key == 'c':
                    # Clear cache & force immediate refresh
                    last_track_id = None
                    pending_track = None
                    pending_time = None
                    print("\n🗑️  Cache reset - will re-download current track")
                    print("   Note: ESP32 SD cache remains (no BLE clear command)")

                elif key == 'h':
                    # Show help
                    print("\n⌨  Keyboard Commands:")
                    print("  s - Show statistics")
                    print("  v - Toggle verbose logging")
                    print("  r - Force refresh next track")
                    print("  c - Clear cache & force re-download")
                    print("  h - Show this help\n")

            await asyncio.sleep(1.0)  # Poll every 1s - safe for Spotify API limits (60 req/min)

    except KeyboardInterrupt:
        print("\n\nShutting down...")
        stats.print_summary()
    finally:
        if client.is_connected:
            await client.disconnect()
            print("BLE Disconnected")


def main():
    """Entry point - runs async event loop"""
    asyncio.run(main_async())


if __name__ == "__main__":
    main()