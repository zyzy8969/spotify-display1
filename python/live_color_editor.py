"""
Live Color Editor - Real-time interactive color adjustment for ESP32 display
Adjust settings with keyboard, instantly preview on display
"""

import requests
import time
import io
import struct
import asyncio
from PIL import Image
from wand.image import Image as WandImage
from bleak import BleakClient, BleakScanner
from bleak.exc import BleakError
import os
import sys

# ==================================================
# ESP32 BLE CONFIGURATION
# ==================================================

BLE_NAME = "Spotify Display"
SERVICE_UUID = "0000ffe0-0000-1000-8000-00805f9b34fb"
STATUS_CHAR_UUID = "0000ffe1-0000-1000-8000-00805f9b34fb"
IMAGE_CHAR_UUID = "0000ffe3-0000-1000-8000-00805f9b34fb"
MESSAGE_CHAR_UUID = "0000ffe4-0000-1000-8000-00805f9b34fb"

CHUNK_SIZE = 512
DISPLAY_WIDTH = 240
DISPLAY_HEIGHT = 240

# Test image URL
TEST_IMAGE_URL = "https://i.scdn.co/image/ab67616d0000b273e8b066f70c206551210d902b"

# ==================================================
# SETTINGS CLASS
# ==================================================

class ColorSettings:
    """Manages color adjustment settings"""
    def __init__(self):
        # Current settings
        self.saturation = 135
        self.brightness = 90
        self.contrast = 12
        self.level_black = 0.10
        self.level_white = 0.90
        self.level_gamma = 1.12

        # Cached image data
        self.original_image_data = None

    def get_dict(self):
        """Return settings as dictionary"""
        return {
            'LEVEL_METHOD': 'level',
            'LEVEL_BLACK': self.level_black,
            'LEVEL_WHITE': self.level_white,
            'LEVEL_GAMMA': self.level_gamma,
            'SATURATION': self.saturation,
            'BRIGHTNESS_ADJUST': self.brightness,
            'CONTRAST': self.contrast
        }

    def adjust(self, param, delta):
        """Adjust a parameter by delta"""
        if param == 'saturation':
            self.saturation = max(0, min(200, self.saturation + delta))
        elif param == 'brightness':
            self.brightness = max(50, min(150, self.brightness + delta))
        elif param == 'contrast':
            self.contrast = max(0, min(50, self.contrast + delta))
        elif param == 'level_black':
            self.level_black = max(0.0, min(0.5, round(self.level_black + delta, 2)))
        elif param == 'level_white':
            self.level_white = max(0.5, min(1.0, round(self.level_white + delta, 2)))
        elif param == 'level_gamma':
            self.level_gamma = max(0.5, min(2.0, round(self.level_gamma + delta, 2)))

# ==================================================
# BLE CONTEXT
# ==================================================

class BLEContext:
    def __init__(self):
        self.ready_event = asyncio.Event()
        self.transfer_complete_event = asyncio.Event()

    def reset_transfer(self):
        self.transfer_complete_event.clear()

    def notification_handler(self, sender, data):
        if sender == IMAGE_CHAR_UUID:
            if len(data) == 1 and data[0] == 0x01:
                self.transfer_complete_event.set()
        elif sender == MESSAGE_CHAR_UUID:
            msg = data.decode('utf-8', errors='ignore')
            if msg == "READY":
                self.ready_event.set()
            elif msg == "SUCCESS":
                self.transfer_complete_event.set()

# ==================================================
# IMAGE PROCESSING
# ==================================================

def convert_to_rgb565(img):
    """Convert PIL image to RGB565"""
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

def process_image(image_data, settings_dict):
    """Process image with settings"""
    with WandImage(blob=image_data) as wand_img:
        wand_img.resize(DISPLAY_WIDTH, DISPLAY_HEIGHT, filter='lanczos')

        wand_img.level(
            black=settings_dict['LEVEL_BLACK'],
            white=settings_dict['LEVEL_WHITE'],
            gamma=settings_dict['LEVEL_GAMMA']
        )

        wand_img.modulate(
            brightness=settings_dict['BRIGHTNESS_ADJUST'],
            saturation=settings_dict['SATURATION'],
            hue=100
        )
        wand_img.brightness_contrast(brightness=0, contrast=settings_dict['CONTRAST'])

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

async def find_display():
    devices = await BleakScanner.discover(timeout=5.0)
    for device in devices:
        if device.name == BLE_NAME:
            return device.address
    return None

async def send_image_fast(client, ctx, rgb565_data):
    """Fast image send without progress"""
    ctx.reset_transfer()

    size_packet = struct.pack('<I', len(rgb565_data))
    await client.write_gatt_char(IMAGE_CHAR_UUID, size_packet)
    await asyncio.sleep(0.01)

    for i in range(0, len(rgb565_data), CHUNK_SIZE):
        chunk = rgb565_data[i:i+CHUNK_SIZE]
        await client.write_gatt_char(IMAGE_CHAR_UUID, chunk, response=False)
        await asyncio.sleep(0.002)

    try:
        await asyncio.wait_for(ctx.transfer_complete_event.wait(), timeout=10.0)
        return True
    except asyncio.TimeoutError:
        return False

# ==================================================
# KEYBOARD INPUT
# ==================================================

def get_key_windows():
    """Non-blocking keyboard input for Windows"""
    import msvcrt
    if msvcrt.kbhit():
        key = msvcrt.getch()
        # Handle special keys
        if key == b'\xe0' or key == b'\x00':  # Arrow keys prefix
            key = msvcrt.getch()
            if key == b'H':  # Up arrow
                return 'up'
            elif key == b'P':  # Down arrow
                return 'down'
            elif key == b'M':  # Right arrow
                return 'right'
            elif key == b'K':  # Left arrow
                return 'left'
        else:
            return key.decode('utf-8', errors='ignore').lower()
    return None

# ==================================================
# LIVE EDITOR
# ==================================================

async def live_editor():
    """Interactive live color editor"""

    # Clear screen
    os.system('cls' if os.name == 'nt' else 'clear')

    print("=" * 70)
    print("LIVE COLOR EDITOR - ESP32 Display")
    print("=" * 70)
    print()

    # Load test image
    print("Loading test image...")
    response = requests.get(TEST_IMAGE_URL, timeout=10)
    original_image_data = response.content
    print("✓ Image loaded\n")

    # Connect to ESP32
    print("Connecting to ESP32...")
    address = await find_display()
    if not address:
        print("✗ Could not find ESP32!")
        return

    client = BleakClient(address)
    await client.connect()
    ctx = BLEContext()

    await client.start_notify(STATUS_CHAR_UUID, ctx.notification_handler)
    await client.start_notify(IMAGE_CHAR_UUID, ctx.notification_handler)
    await client.start_notify(MESSAGE_CHAR_UUID, ctx.notification_handler)

    try:
        await asyncio.wait_for(ctx.ready_event.wait(), timeout=5.0)
    except:
        pass

    print("✓ Connected\n")

    # Initialize settings
    settings = ColorSettings()
    settings.original_image_data = original_image_data

    # Current selection
    params = ['saturation', 'brightness', 'contrast', 'level_black', 'level_white', 'level_gamma']
    param_names = ['Saturation', 'Brightness', 'Contrast', 'Level Black', 'Level White', 'Level Gamma']
    current_param = 0

    # Send initial image
    print("Sending initial image...")
    rgb565 = process_image(original_image_data, settings.get_dict())
    await send_image_fast(client, ctx, rgb565)
    print("✓ Ready\n")

    def display_ui():
        """Display the UI"""
        os.system('cls' if os.name == 'nt' else 'clear')
        print("=" * 70)
        print("LIVE COLOR EDITOR".center(70))
        print("=" * 70)
        print()

        print("CONTROLS:")
        print("  ↑/↓  Select parameter    │  ←/→  Adjust value    │  SPACE  Send to display")
        print("  r    Reset to defaults   │  q    Quit")
        print("=" * 70)
        print()

        print("CURRENT SETTINGS:")
        print()

        for i, (param, name) in enumerate(zip(params, param_names)):
            value = getattr(settings, param)

            # Format value display
            if param in ['saturation', 'brightness', 'contrast']:
                value_str = f"{int(value):3d}"
                bar_max = 200 if param == 'saturation' else (150 if param == 'brightness' else 50)
                bar_length = 30
                filled = int((value / bar_max) * bar_length)
                bar = '█' * filled + '░' * (bar_length - filled)
            else:
                value_str = f"{value:.2f}"
                bar_length = 30
                filled = int((value / 1.0) * bar_length) if param != 'level_gamma' else int(((value - 0.5) / 1.5) * bar_length)
                bar = '█' * filled + '░' * (bar_length - filled)

            # Highlight current parameter
            marker = "► " if i == current_param else "  "
            print(f"{marker}{name:<15} [{bar}] {value_str}")

        print()
        print("=" * 70)
        print("Tip: Adjust settings with ←/→ arrows, press SPACE to preview on display")
        print()

    # Main loop
    display_ui()

    last_send_time = time.time()
    auto_send_delay = 0.5  # Auto-send after 0.5s of inactivity

    try:
        while True:
            key = get_key_windows()

            if key:
                if key == 'q':
                    break

                elif key == 'up':
                    current_param = (current_param - 1) % len(params)
                    display_ui()

                elif key == 'down':
                    current_param = (current_param + 1) % len(params)
                    display_ui()

                elif key == 'left':
                    param = params[current_param]
                    if param == 'saturation':
                        settings.adjust(param, -5)
                    elif param == 'brightness':
                        settings.adjust(param, -5)
                    elif param == 'contrast':
                        settings.adjust(param, -1)
                    else:
                        settings.adjust(param, -0.05)
                    last_send_time = time.time()
                    display_ui()

                elif key == 'right':
                    param = params[current_param]
                    if param == 'saturation':
                        settings.adjust(param, 5)
                    elif param == 'brightness':
                        settings.adjust(param, 5)
                    elif param == 'contrast':
                        settings.adjust(param, 1)
                    else:
                        settings.adjust(param, 0.05)
                    last_send_time = time.time()
                    display_ui()

                elif key == ' ':
                    # Manual send
                    print("\nProcessing and sending...")
                    rgb565 = process_image(original_image_data, settings.get_dict())
                    success = await send_image_fast(client, ctx, rgb565)
                    if success:
                        print("✓ Sent to display")
                    else:
                        print("✗ Send failed")
                    last_send_time = time.time()
                    await asyncio.sleep(0.5)
                    display_ui()

                elif key == 'r':
                    # Reset to defaults
                    settings = ColorSettings()
                    settings.original_image_data = original_image_data
                    print("\nReset to defaults, sending...")
                    rgb565 = process_image(original_image_data, settings.get_dict())
                    await send_image_fast(client, ctx, rgb565)
                    print("✓ Reset complete")
                    last_send_time = time.time()
                    await asyncio.sleep(0.5)
                    display_ui()

                elif key == 'p':
                    # Print current settings for copying
                    print("\nCurrent settings (copy to spotify_album_sender.py):")
                    print(f"SATURATION = {settings.saturation}")
                    print(f"BRIGHTNESS_ADJUST = {settings.brightness}")
                    print(f"CONTRAST = {settings.contrast}")
                    print(f"LEVEL_BLACK = {settings.level_black}")
                    print(f"LEVEL_WHITE = {settings.level_white}")
                    print(f"LEVEL_GAMMA = {settings.level_gamma}")
                    print("\nPress any key to continue...")
                    while not get_key_windows():
                        await asyncio.sleep(0.01)
                    display_ui()

            # Auto-send after inactivity
            if time.time() - last_send_time > auto_send_delay and last_send_time > 0:
                rgb565 = process_image(original_image_data, settings.get_dict())
                await send_image_fast(client, ctx, rgb565)
                last_send_time = 0  # Prevent re-sending

            await asyncio.sleep(0.05)

    except KeyboardInterrupt:
        pass

    finally:
        await client.disconnect()
        print("\n\n✓ Disconnected")
        print("\nFinal settings:")
        print(f"  SATURATION = {settings.saturation}")
        print(f"  BRIGHTNESS_ADJUST = {settings.brightness}")
        print(f"  CONTRAST = {settings.contrast}")
        print(f"  LEVEL_BLACK = {settings.level_black}")
        print(f"  LEVEL_WHITE = {settings.level_white}")
        print(f"  LEVEL_GAMMA = {settings.level_gamma}")

# ==================================================
# MAIN
# ==================================================

if __name__ == "__main__":
    asyncio.run(live_editor())
