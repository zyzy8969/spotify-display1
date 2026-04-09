"""
Color Test Tool - Test ImageMagick settings on ESP32 display
Allows quick tweaking of saturation, brightness, contrast, and level adjustments
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
import hashlib

# ==================================================
# ESP32 BLE CONFIGURATION
# ==================================================

BLE_NAME = "Spotify Display"

# BLE UUIDs
SERVICE_UUID = "0000ffe0-0000-1000-8000-00805f9b34fb"
STATUS_CHAR_UUID = "0000ffe1-0000-1000-8000-00805f9b34fb"
CACHE_CHAR_UUID = "0000ffe2-0000-1000-8000-00805f9b34fb"
IMAGE_CHAR_UUID = "0000ffe3-0000-1000-8000-00805f9b34fb"
MESSAGE_CHAR_UUID = "0000ffe4-0000-1000-8000-00805f9b34fb"

# Transfer settings
CHUNK_SIZE = 512
DISPLAY_WIDTH = 240
DISPLAY_HEIGHT = 240

# ==================================================
# IMAGE PROCESSING SETTINGS - TWEAK THESE!
# ==================================================

# Test image URL (use any square album art or test image)
TEST_IMAGE_URL = "https://i.scdn.co/image/ab67616d0000b273e8b066f70c206551210d902b"  # Bohemian Rhapsody
# Or use a local file: TEST_IMAGE_PATH = "test_image.jpg"
USE_LOCAL_IMAGE = False
TEST_IMAGE_PATH = "test_image.jpg"

# === COLOR ADJUSTMENT METHODS ===
# Options: 'normalize', 'auto_level', 'sigmoidal', 'level', 'none'
LEVEL_METHOD = 'level'

# Level method settings (used when LEVEL_METHOD = 'level')
LEVEL_BLACK = 0.10      # Black point (0.0-1.0) - higher = deeper blacks
LEVEL_WHITE = 0.90      # White point (0.0-1.0) - lower = brighter whites
LEVEL_GAMMA = 1.12      # Gamma correction (0.5-2.0) - 1.0 = no change

# Sigmoidal settings (used when LEVEL_METHOD = 'sigmoidal')
SIGMOIDAL_STRENGTH = 3.0
SIGMOIDAL_MIDPOINT = 0.50

# === COLOR ENHANCEMENT ===
SATURATION = 135        # Color saturation (0-200, 100 = normal)
BRIGHTNESS_ADJUST = 90  # Brightness adjustment (0-200, 100 = normal)
CONTRAST = 12           # Contrast boost (0-50, 0 = none)

# === DISPLAY OPTIONS ===
SHOW_PROGRESS = True    # Show processing progress
APPLY_DITHERING = True  # Note: Floyd-Steinberg dithering happens on ESP32

# ==================================================
# PRESET CONFIGURATIONS
# ==================================================

PRESETS = {
    'vibrant': {
        'LEVEL_METHOD': 'level',
        'LEVEL_BLACK': 0.10,
        'LEVEL_WHITE': 0.90,
        'LEVEL_GAMMA': 1.12,
        'SATURATION': 135,
        'BRIGHTNESS_ADJUST': 90,
        'CONTRAST': 12,
        'description': 'Vibrant colors, deep blacks (current default)'
    },
    'natural': {
        'LEVEL_METHOD': 'level',
        'LEVEL_BLACK': 0.05,
        'LEVEL_WHITE': 0.95,
        'LEVEL_GAMMA': 1.0,
        'SATURATION': 100,
        'BRIGHTNESS_ADJUST': 100,
        'CONTRAST': 5,
        'description': 'Natural, unprocessed look'
    },
    'punchy': {
        'LEVEL_METHOD': 'level',
        'LEVEL_BLACK': 0.15,
        'LEVEL_WHITE': 0.85,
        'LEVEL_GAMMA': 1.2,
        'SATURATION': 150,
        'BRIGHTNESS_ADJUST': 95,
        'CONTRAST': 15,
        'description': 'Extra saturated, high contrast'
    },
    'pastel': {
        'LEVEL_METHOD': 'level',
        'LEVEL_BLACK': 0.05,
        'LEVEL_WHITE': 0.98,
        'LEVEL_GAMMA': 0.9,
        'SATURATION': 80,
        'BRIGHTNESS_ADJUST': 110,
        'CONTRAST': 3,
        'description': 'Soft, pastel colors'
    },
    'dramatic': {
        'LEVEL_METHOD': 'sigmoidal',
        'SIGMOIDAL_STRENGTH': 5.0,
        'SIGMOIDAL_MIDPOINT': 0.50,
        'SATURATION': 120,
        'BRIGHTNESS_ADJUST': 85,
        'CONTRAST': 20,
        'description': 'Dramatic sigmoidal curve, high contrast'
    }
}

# ==================================================
# BLE CONTEXT
# ==================================================

class BLEContext:
    """Manages BLE connection state"""
    def __init__(self):
        self.ready_event = asyncio.Event()
        self.transfer_complete_event = asyncio.Event()
        self.messages = []

    def reset_transfer(self):
        self.transfer_complete_event.clear()
        self.messages = []

    def notification_handler(self, sender, data):
        """Handle BLE notifications"""
        if sender == STATUS_CHAR_UUID:
            pass
        elif sender == IMAGE_CHAR_UUID:
            if len(data) == 1 and data[0] == 0x01:
                self.transfer_complete_event.set()
        elif sender == MESSAGE_CHAR_UUID:
            msg = data.decode('utf-8', errors='ignore')
            self.messages.append(msg)
            if msg == "READY":
                self.ready_event.set()
            elif msg == "SUCCESS":
                self.transfer_complete_event.set()

# ==================================================
# IMAGE PROCESSING
# ==================================================

def convert_to_rgb565(img):
    """Convert PIL image to RGB565 bytes"""
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

def process_image(image_data, settings):
    """Process image with specified settings"""

    if SHOW_PROGRESS:
        print("  Processing with ImageMagick...")

    with WandImage(blob=image_data) as wand_img:
        # Resize
        wand_img.resize(DISPLAY_WIDTH, DISPLAY_HEIGHT, filter='lanczos')

        # Apply level adjustment
        if settings['LEVEL_METHOD'] == 'normalize':
            if SHOW_PROGRESS:
                print("    - Applying normalize")
            wand_img.normalize()

        elif settings['LEVEL_METHOD'] == 'auto_level':
            if SHOW_PROGRESS:
                print("    - Applying auto_level")
            wand_img.auto_level()

        elif settings['LEVEL_METHOD'] == 'sigmoidal':
            if SHOW_PROGRESS:
                print(f"    - Applying sigmoidal (strength={settings.get('SIGMOIDAL_STRENGTH', 3.0)}, midpoint={settings.get('SIGMOIDAL_MIDPOINT', 0.5)})")
            wand_img.sigmoidal_contrast(
                sharpen=True,
                strength=settings.get('SIGMOIDAL_STRENGTH', 3.0),
                midpoint=settings.get('SIGMOIDAL_MIDPOINT', 0.50)
            )

        elif settings['LEVEL_METHOD'] == 'level':
            if SHOW_PROGRESS:
                print(f"    - Applying level (black={settings['LEVEL_BLACK']}, white={settings['LEVEL_WHITE']}, gamma={settings['LEVEL_GAMMA']})")
            wand_img.level(
                black=settings['LEVEL_BLACK'],
                white=settings['LEVEL_WHITE'],
                gamma=settings['LEVEL_GAMMA']
            )

        # Apply color adjustments
        if SHOW_PROGRESS:
            print(f"    - Saturation: {settings['SATURATION']}, Brightness: {settings['BRIGHTNESS_ADJUST']}, Contrast: {settings['CONTRAST']}")

        wand_img.modulate(
            brightness=settings['BRIGHTNESS_ADJUST'],
            saturation=settings['SATURATION'],
            hue=100
        )
        wand_img.brightness_contrast(brightness=0, contrast=settings['CONTRAST'])

        # Convert to PIL
        pil_bytes = io.BytesIO()
        wand_img.format = 'png'
        wand_img.save(file=pil_bytes)
        pil_bytes.seek(0)
        img = Image.open(pil_bytes)

    if img.mode != 'RGB':
        img = img.convert('RGB')

    if SHOW_PROGRESS:
        print("  Converting to RGB565...")

    rgb565_data = convert_to_rgb565(img)

    if SHOW_PROGRESS:
        print(f"  ✓ Processed: {len(rgb565_data)} bytes")

    return rgb565_data

# ==================================================
# BLE FUNCTIONS
# ==================================================

async def find_display():
    """Find ESP32 BLE device"""
    print(f"Searching for '{BLE_NAME}'...")
    devices = await BleakScanner.discover(timeout=5.0)

    for device in devices:
        if device.name == BLE_NAME:
            print(f"✓ Found: {device.address}")
            return device.address

    return None

async def connect_to_display(address):
    """Connect to ESP32"""
    client = BleakClient(address)
    await client.connect()
    print(f"✓ Connected")

    ctx = BLEContext()

    # Setup notifications
    await client.start_notify(STATUS_CHAR_UUID, ctx.notification_handler)
    await client.start_notify(IMAGE_CHAR_UUID, ctx.notification_handler)
    await client.start_notify(MESSAGE_CHAR_UUID, ctx.notification_handler)

    # Wait for READY
    try:
        await asyncio.wait_for(ctx.ready_event.wait(), timeout=5.0)
        print("✓ ESP32 ready")
    except asyncio.TimeoutError:
        print("⚠ No READY signal (proceeding anyway)")

    return client, ctx

async def send_image(client, ctx, image_data):
    """Send image to ESP32"""
    ctx.reset_transfer()

    # Send size header
    size_packet = struct.pack('<I', len(image_data))
    await client.write_gatt_char(IMAGE_CHAR_UUID, size_packet)
    await asyncio.sleep(0.01)

    # Send data
    if SHOW_PROGRESS:
        print(f"  Transferring {len(image_data)} bytes...")

    total_sent = 0
    start_time = time.time()

    for i in range(0, len(image_data), CHUNK_SIZE):
        chunk = image_data[i:i+CHUNK_SIZE]
        await client.write_gatt_char(IMAGE_CHAR_UUID, chunk, response=False)
        total_sent += len(chunk)

        if SHOW_PROGRESS:
            progress = int((total_sent / len(image_data)) * 100)
            bar_length = 20
            filled = int((total_sent / len(image_data)) * bar_length)
            bar = '█' * filled + '·' * (bar_length - filled)
            print(f"  Transfer: [{bar}] {progress}%", end='\r')

        await asyncio.sleep(0.002)

    if SHOW_PROGRESS:
        print()

    # Wait for confirmation
    try:
        await asyncio.wait_for(ctx.transfer_complete_event.wait(), timeout=10.0)
        transfer_time = time.time() - start_time
        speed_kbps = (len(image_data) / 1024) / transfer_time
        print(f"  ✓ Complete: {transfer_time:.2f}s @ {speed_kbps:.1f} KB/s")
    except asyncio.TimeoutError:
        print("  ✗ Transfer timeout")

# ==================================================
# MAIN TEST FUNCTION
# ==================================================

async def test_color_settings(preset_name=None):
    """Test color settings on ESP32 display"""

    print("=" * 60)
    print("ESP32 Color Test Tool")
    print("=" * 60)

    # Load settings
    if preset_name and preset_name in PRESETS:
        settings = PRESETS[preset_name].copy()
        print(f"\n📋 Using preset: '{preset_name}'")
        print(f"   {settings.pop('description', '')}\n")
    else:
        settings = {
            'LEVEL_METHOD': LEVEL_METHOD,
            'LEVEL_BLACK': LEVEL_BLACK,
            'LEVEL_WHITE': LEVEL_WHITE,
            'LEVEL_GAMMA': LEVEL_GAMMA,
            'SIGMOIDAL_STRENGTH': SIGMOIDAL_STRENGTH,
            'SIGMOIDAL_MIDPOINT': SIGMOIDAL_MIDPOINT,
            'SATURATION': SATURATION,
            'BRIGHTNESS_ADJUST': BRIGHTNESS_ADJUST,
            'CONTRAST': CONTRAST
        }
        print("\n⚙️  Using custom settings from top of file\n")

    # Display current settings
    print("Current Settings:")
    print(f"  Method: {settings['LEVEL_METHOD']}")
    if settings['LEVEL_METHOD'] == 'level':
        print(f"  Black: {settings['LEVEL_BLACK']}, White: {settings['LEVEL_WHITE']}, Gamma: {settings['LEVEL_GAMMA']}")
    elif settings['LEVEL_METHOD'] == 'sigmoidal':
        print(f"  Strength: {settings.get('SIGMOIDAL_STRENGTH')}, Midpoint: {settings.get('SIGMOIDAL_MIDPOINT')}")
    print(f"  Saturation: {settings['SATURATION']}")
    print(f"  Brightness: {settings['BRIGHTNESS_ADJUST']}")
    print(f"  Contrast: {settings['CONTRAST']}")
    print()

    # Load test image
    if USE_LOCAL_IMAGE:
        print(f"Loading local image: {TEST_IMAGE_PATH}...")
        with open(TEST_IMAGE_PATH, 'rb') as f:
            image_data = f.read()
    else:
        print(f"Downloading test image...")
        print(f"  URL: {TEST_IMAGE_URL[:60]}...")
        response = requests.get(TEST_IMAGE_URL, timeout=10)
        response.raise_for_status()
        image_data = response.content
        print(f"  ✓ Downloaded: {len(image_data)} bytes")

    # Process image
    print("\nProcessing image...")
    rgb565_data = process_image(image_data, settings)

    # Connect to ESP32
    print("\nConnecting to ESP32...")
    address = await find_display()
    if not address:
        print("✗ Could not find ESP32!")
        return

    client, ctx = await connect_to_display(address)

    # Send to display
    print("\nSending to display...")
    await send_image(client, ctx, rgb565_data)

    # Cleanup
    await client.disconnect()
    print("\n✓ Test complete!")
    print("\nTip: Edit settings at top of file and run again to compare")

# ==================================================
# CLI INTERFACE
# ==================================================

async def interactive_test():
    """Interactive testing mode"""
    print("=" * 60)
    print("ESP32 Color Test - Interactive Mode")
    print("=" * 60)
    print("\nAvailable presets:")
    for i, (name, preset) in enumerate(PRESETS.items(), 1):
        print(f"  {i}. {name:<12} - {preset['description']}")
    print(f"  {len(PRESETS)+1}. custom      - Use settings from file")
    print("\nEnter preset number (or 'q' to quit): ", end='')

    choice = input().strip()

    if choice.lower() == 'q':
        return

    try:
        choice_num = int(choice)
        if choice_num <= len(PRESETS):
            preset_name = list(PRESETS.keys())[choice_num - 1]
            await test_color_settings(preset_name)
        elif choice_num == len(PRESETS) + 1:
            await test_color_settings(None)
        else:
            print("Invalid choice")
    except ValueError:
        print("Invalid choice")

# ==================================================
# MAIN
# ==================================================

if __name__ == "__main__":
    import sys

    if len(sys.argv) > 1:
        # Command line mode: python color_test.py <preset_name>
        preset = sys.argv[1]
        if preset in PRESETS:
            asyncio.run(test_color_settings(preset))
        else:
            print(f"Unknown preset: {preset}")
            print(f"Available: {', '.join(PRESETS.keys())}")
    else:
        # Interactive mode
        asyncio.run(interactive_test())
