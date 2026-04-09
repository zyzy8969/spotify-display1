# Waveshare ESP32-S3 1.3" LCD Module - Gamma & Dithering Reference

## Hardware Specifications

| Parameter | Value |
|-----------|-------|
| **Display Size** | 1.3 inch diagonal |
| **Resolution** | 240×240 pixels |
| **Dot Pitch** | 0.0975mm × 0.0975mm |
| **Active Area** | 23.4mm × 23.4mm |
| **Driver IC** | ST7789VW |
| **Interface** | 4-Line SPI |
| **Color Arrangement** | RGB Vertical Stripe |
| **Display Mode** | Normally Black |

### Electrical Characteristics

| Parameter | Min | Typ | Max | Unit |
|-----------|-----|-----|-----|------|
| VDD (System) | 2.4 | 2.8 | 3.3 | V |
| VDDIO (I/O) | 1.65 | 1.8 | 3.3 | V |
| IDD (Operating) | - | 8 | 10 | mA |
| VLED (Backlight) | 2.8 | - | 3.0 | V |
| ILED (Backlight) | 30 | - | 40 | mA |
| **Brightness** | 200 | **250** | - | cd/m² |

### Optical Characteristics

| Parameter | Value | Unit |
|-----------|-------|------|
| Contrast Ratio | 640-800:1 | - |
| Response Time | 30-35 | ms |
| Viewing Angle | 80° all directions | degrees |
| Transmittance | 4.18-4.65 | % |

### CIE Color Coordinates

| Color | X | Y |
|-------|------|------|
| White | 0.302 | 0.325 |
| Red | 0.624 | 0.329 |
| Green | 0.288 | 0.522 |
| Blue | 0.136 | 0.137 |

---

## Pin Configuration (12-Pin FPC)

| Pin | Symbol | Function | ESP32-S3 GPIO |
|-----|--------|----------|---------------|
| 1 | GND | Ground | GND |
| 2 | LEDK | LED Cathode | GND (or PWM for dimming) |
| 3 | LEDA | LED Anode | 3.3V |
| 4 | VDD | Power (2.4-3.3V) | 3.3V |
| 5 | GND | Ground | GND |
| 6 | GND | Ground | GND |
| 7 | D/C | Data/Command | GPIO (e.g., 4) |
| 8 | CS | Chip Select | GPIO (e.g., 5) |
| 9 | SCL | SPI Clock | GPIO (e.g., 6) |
| 10 | SDA | SPI Data (MOSI) | GPIO (e.g., 7) |
| 11 | RESET | Hardware Reset | GPIO (e.g., 8) |
| 12 | GND | Ground | GND |

---

## Complete Python Implementation for ESP32-S3

### MicroPython Display Driver with Gamma Support

```python
"""
ST7789VW Display Driver for Waveshare ESP32-S3 1.3" LCD
Includes gamma correction and dithering support
"""

from machine import Pin, SPI
import time
import struct

class ST7789:
    # Display dimensions
    WIDTH = 240
    HEIGHT = 240
    
    # Commands
    CMD_NOP = 0x00
    CMD_SWRESET = 0x01
    CMD_SLPIN = 0x10
    CMD_SLPOUT = 0x11
    CMD_INVOFF = 0x20
    CMD_INVON = 0x21
    CMD_GAMSET = 0x26
    CMD_DISPOFF = 0x28
    CMD_DISPON = 0x29
    CMD_CASET = 0x2A
    CMD_RASET = 0x2B
    CMD_RAMWR = 0x2C
    CMD_MADCTL = 0x36
    CMD_COLMOD = 0x3A
    CMD_PVGAMCTRL = 0xE0
    CMD_NVGAMCTRL = 0xE1
    CMD_DGMEN = 0xBA
    CMD_DGMLUTR = 0xE2
    CMD_DGMLUTB = 0xE3
    
    # Gamma presets
    GAMMA_2_2 = 0x01  # Default sRGB
    GAMMA_1_8 = 0x02  # Lighter
    GAMMA_2_5 = 0x04  # Darker
    GAMMA_1_0 = 0x08  # Linear
    
    def __init__(self, spi, dc, cs, rst, bl=None):
        """
        Initialize display
        
        Args:
            spi: SPI object
            dc: Data/Command pin
            cs: Chip Select pin
            rst: Reset pin
            bl: Backlight pin (optional, for PWM dimming)
        """
        self.spi = spi
        self.dc = dc
        self.cs = cs
        self.rst = rst
        self.bl = bl
        
        # Pre-compute gamma LUTs
        self._gamma_lut_r = self._create_gamma_lut(2.2)
        self._gamma_lut_g = self._create_gamma_lut(2.2)
        self._gamma_lut_b = self._create_gamma_lut(2.2)
        
        self.init()
    
    def _create_gamma_lut(self, gamma, bits_out=8):
        """Create gamma correction LUT"""
        lut = []
        for i in range(256):
            corrected = pow(i / 255.0, gamma) * 255.0
            lut.append(int(round(corrected)))
        return bytes(lut)
    
    def _write_cmd(self, cmd):
        """Write command byte"""
        self.cs.off()
        self.dc.off()
        self.spi.write(bytes([cmd]))
        self.cs.on()
    
    def _write_data(self, data):
        """Write data bytes"""
        self.cs.off()
        self.dc.on()
        if isinstance(data, int):
            self.spi.write(bytes([data]))
        else:
            self.spi.write(data)
        self.cs.on()
    
    def _write_cmd_data(self, cmd, data):
        """Write command followed by data"""
        self._write_cmd(cmd)
        self._write_data(data)
    
    def reset(self):
        """Hardware reset"""
        self.rst.on()
        time.sleep_ms(10)
        self.rst.off()
        time.sleep_ms(10)
        self.rst.on()
        time.sleep_ms(120)
    
    def init(self):
        """Initialize display with optimal gamma settings"""
        self.reset()
        
        # Software reset
        self._write_cmd(self.CMD_SWRESET)
        time.sleep_ms(150)
        
        # Sleep out
        self._write_cmd(self.CMD_SLPOUT)
        time.sleep_ms(120)
        
        # Memory access control (orientation)
        # MY=0, MX=0, MV=0, ML=0, RGB=0, MH=0
        self._write_cmd_data(self.CMD_MADCTL, 0x00)
        
        # Interface pixel format: RGB565 (16-bit)
        self._write_cmd_data(self.CMD_COLMOD, 0x55)
        
        # Set gamma curve to 2.2 (sRGB standard)
        self._write_cmd_data(self.CMD_GAMSET, self.GAMMA_2_2)
        
        # Positive voltage gamma control (optimized for this panel)
        self._write_cmd(self.CMD_PVGAMCTRL)
        self._write_data(bytes([
            0xD0,  # V63P=13, V0P=0
            0x04,  # V1P=4
            0x0D,  # V2P=13
            0x11,  # V4P=17
            0x13,  # V6P=19
            0x2B,  # J0P=2, V13P=11
            0x3F,  # V20P=63
            0x54,  # V36P=5, V27P=4
            0x4C,  # V43P=76
            0x18,  # J1P=1, V50P=8
            0x0D,  # V57P=13
            0x0B,  # V59P=11
            0x1F,  # V61P=31
            0x23   # V62P=35
        ]))
        
        # Negative voltage gamma control
        self._write_cmd(self.CMD_NVGAMCTRL)
        self._write_data(bytes([
            0xD0,  # V63N=13, V0N=0
            0x04,  # V1N=4
            0x0C,  # V2N=12
            0x11,  # V4N=17
            0x13,  # V6N=19
            0x2C,  # J0N=2, V13N=12
            0x3F,  # V20N=63
            0x44,  # V36N=4, V27N=4
            0x51,  # V43N=81
            0x2F,  # J1N=2, V50N=15
            0x1F,  # V57N=31
            0x1F,  # V59N=31
            0x20,  # V61N=32
            0x23   # V62N=35
        ]))
        
        # Display inversion on (typically needed for this panel)
        self._write_cmd(self.CMD_INVON)
        
        # Display on
        self._write_cmd(self.CMD_DISPON)
        time.sleep_ms(20)
        
        # Turn on backlight if available
        if self.bl:
            self.bl.on()
    
    def set_gamma_preset(self, preset):
        """
        Set gamma curve preset
        
        Args:
            preset: GAMMA_2_2, GAMMA_1_8, GAMMA_2_5, or GAMMA_1_0
        """
        self._write_cmd_data(self.CMD_GAMSET, preset)
    
    def set_custom_gamma(self, positive, negative):
        """
        Set custom gamma curves
        
        Args:
            positive: 14-byte list for positive gamma
            negative: 14-byte list for negative gamma
        """
        self._write_cmd(self.CMD_PVGAMCTRL)
        self._write_data(bytes(positive))
        self._write_cmd(self.CMD_NVGAMCTRL)
        self._write_data(bytes(negative))
    
    def enable_digital_gamma(self, enable=True):
        """Enable/disable per-channel digital gamma LUTs"""
        self._write_cmd_data(self.CMD_DGMEN, 0x04 if enable else 0x00)
    
    def set_red_gamma_lut(self, lut):
        """Set 64-byte red channel gamma LUT"""
        self._write_cmd(self.CMD_DGMLUTR)
        self._write_data(bytes(lut[:64]))
    
    def set_blue_gamma_lut(self, lut):
        """Set 64-byte blue channel gamma LUT"""
        self._write_cmd(self.CMD_DGMLUTB)
        self._write_data(bytes(lut[:64]))
    
    def set_window(self, x0, y0, x1, y1):
        """Set drawing window"""
        # Column address
        self._write_cmd(self.CMD_CASET)
        self._write_data(struct.pack('>HH', x0, x1))
        # Row address
        self._write_cmd(self.CMD_RASET)
        self._write_data(struct.pack('>HH', y0, y1))
    
    def fill_rect(self, x, y, w, h, color):
        """Fill rectangle with color (RGB565)"""
        self.set_window(x, y, x + w - 1, y + h - 1)
        self._write_cmd(self.CMD_RAMWR)
        
        # Prepare color bytes
        hi = (color >> 8) & 0xFF
        lo = color & 0xFF
        
        # Write pixels
        self.cs.off()
        self.dc.on()
        chunk = bytes([hi, lo] * min(w, 64))
        for _ in range(h):
            remaining = w
            while remaining > 0:
                pixels = min(remaining, 64)
                self.spi.write(chunk[:pixels * 2])
                remaining -= pixels
        self.cs.on()
    
    def fill(self, color):
        """Fill entire screen with color"""
        self.fill_rect(0, 0, self.WIDTH, self.HEIGHT, color)
    
    @staticmethod
    def rgb565(r, g, b):
        """Convert RGB888 to RGB565"""
        return ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3)
    
    @staticmethod
    def rgb565_gamma(r, g, b, gamma=2.2):
        """Convert RGB888 to RGB565 with gamma correction"""
        # Apply gamma
        r = int(pow(r / 255.0, gamma) * 255)
        g = int(pow(g / 255.0, gamma) * 255)
        b = int(pow(b / 255.0, gamma) * 255)
        return ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3)


# =============================================================================
# Dithering Functions
# =============================================================================

def create_linear_lut(gamma=2.2):
    """Create linearization LUT (remove gamma from sRGB input)"""
    return [pow(i / 255.0, gamma) for i in range(256)]

def create_gamma_encode_lut(gamma=2.2):
    """Create gamma encoding LUT (apply gamma for display)"""
    return [int(pow(i / 255.0, 1.0 / gamma) * 255) for i in range(256)]


def dither_floyd_steinberg(image_data, width, height, gamma=2.2):
    """
    Floyd-Steinberg dithering with gamma-aware processing
    
    Args:
        image_data: Flat list of RGB values [r,g,b,r,g,b,...]
        width: Image width
        height: Image height
        gamma: Display gamma (2.2 for sRGB)
    
    Returns:
        list: RGB565 values ready for display
    """
    # Create working buffer (linearized)
    linear_lut = create_linear_lut(gamma)
    buffer = []
    
    for i in range(0, len(image_data), 3):
        r = linear_lut[image_data[i]] * 255
        g = linear_lut[image_data[i + 1]] * 255
        b = linear_lut[image_data[i + 2]] * 255
        buffer.append([r, g, b])
    
    # RGB565 quantization levels
    r_levels = 32  # 5 bits
    g_levels = 64  # 6 bits
    b_levels = 32  # 5 bits
    
    def quantize(val, levels):
        step = 255.0 / (levels - 1)
        return round(val / step) * step
    
    # Apply Floyd-Steinberg dithering
    for y in range(height):
        for x in range(width):
            idx = y * width + x
            old_r, old_g, old_b = buffer[idx]
            
            # Quantize
            new_r = quantize(old_r, r_levels)
            new_g = quantize(old_g, g_levels)
            new_b = quantize(old_b, b_levels)
            
            buffer[idx] = [new_r, new_g, new_b]
            
            # Calculate error
            err_r = old_r - new_r
            err_g = old_g - new_g
            err_b = old_b - new_b
            
            # Distribute error
            def add_error(px, py, factor):
                if 0 <= px < width and 0 <= py < height:
                    i = py * width + px
                    buffer[i][0] = max(0, min(255, buffer[i][0] + err_r * factor))
                    buffer[i][1] = max(0, min(255, buffer[i][1] + err_g * factor))
                    buffer[i][2] = max(0, min(255, buffer[i][2] + err_b * factor))
            
            add_error(x + 1, y, 7/16)
            add_error(x - 1, y + 1, 3/16)
            add_error(x, y + 1, 5/16)
            add_error(x + 1, y + 1, 1/16)
    
    # Convert to RGB565 with gamma re-encoding
    gamma_lut = create_gamma_encode_lut(gamma)
    result = []
    
    for pixel in buffer:
        r = gamma_lut[int(max(0, min(255, pixel[0])))]
        g = gamma_lut[int(max(0, min(255, pixel[1])))]
        b = gamma_lut[int(max(0, min(255, pixel[2])))]
        
        rgb565 = ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3)
        result.append(rgb565)
    
    return result


def dither_ordered_bayer(image_data, width, height, gamma=2.2):
    """
    Ordered (Bayer) dithering - faster than Floyd-Steinberg
    
    Args:
        image_data: Flat list of RGB values
        width: Image width
        height: Image height
        gamma: Display gamma
    
    Returns:
        list: RGB565 values
    """
    # 4x4 Bayer matrix (normalized to 0-15)
    bayer = [
        [ 0,  8,  2, 10],
        [12,  4, 14,  6],
        [ 3, 11,  1,  9],
        [15,  7, 13,  5]
    ]
    
    linear_lut = create_linear_lut(gamma)
    gamma_lut = create_gamma_encode_lut(gamma)
    
    result = []
    
    for y in range(height):
        for x in range(width):
            idx = (y * width + x) * 3
            
            # Linearize input
            r = linear_lut[image_data[idx]] * 255
            g = linear_lut[image_data[idx + 1]] * 255
            b = linear_lut[image_data[idx + 2]] * 255
            
            # Get threshold from Bayer matrix
            threshold = (bayer[y % 4][x % 4] / 16.0 - 0.5) * 32
            
            # Add dither and quantize
            r5 = int(max(0, min(31, (r + threshold) / 8)))
            g6 = int(max(0, min(63, (g + threshold * 0.5) / 4)))
            b5 = int(max(0, min(31, (b + threshold) / 8)))
            
            # Re-apply gamma
            r5 = int(pow(r5 / 31.0, 1/gamma) * 31)
            g6 = int(pow(g6 / 63.0, 1/gamma) * 63)
            b5 = int(pow(b5 / 31.0, 1/gamma) * 31)
            
            rgb565 = (r5 << 11) | (g6 << 5) | b5
            result.append(rgb565)
    
    return result


# =============================================================================
# Example Usage
# =============================================================================

def main():
    """Example initialization and usage"""
    
    # Configure SPI (adjust pins for your wiring)
    spi = SPI(1, baudrate=40_000_000, polarity=0, phase=0,
              sck=Pin(6), mosi=Pin(7))
    
    # Configure control pins
    dc = Pin(4, Pin.OUT)
    cs = Pin(5, Pin.OUT)
    rst = Pin(8, Pin.OUT)
    bl = Pin(9, Pin.OUT)  # Optional backlight control
    
    # Initialize display
    display = ST7789(spi, dc, cs, rst, bl)
    
    # Fill with solid colors to test
    display.fill(ST7789.rgb565(255, 0, 0))    # Red
    time.sleep(1)
    display.fill(ST7789.rgb565(0, 255, 0))    # Green
    time.sleep(1)
    display.fill(ST7789.rgb565(0, 0, 255))    # Blue
    time.sleep(1)
    display.fill(ST7789.rgb565(0, 0, 0))      # Black
    
    # Test gamma presets
    print("Testing gamma presets...")
    for preset, name in [(ST7789.GAMMA_2_2, "2.2"),
                         (ST7789.GAMMA_1_8, "1.8"),
                         (ST7789.GAMMA_2_5, "2.5"),
                         (ST7789.GAMMA_1_0, "1.0")]:
        print(f"  Gamma {name}")
        display.set_gamma_preset(preset)
        
        # Draw gray gradient
        for x in range(240):
            gray = int(x / 240 * 255)
            color = ST7789.rgb565(gray, gray, gray)
            display.fill_rect(x, 0, 1, 240, color)
        time.sleep(2)
    
    # Reset to default gamma
    display.set_gamma_preset(ST7789.GAMMA_2_2)
    
    print("Done!")


if __name__ == "__main__":
    main()
```

---

## Gamma Correction Flow for This Display

```
┌─────────────────────────────────────────────────────────────────┐
│                    IMAGE PROCESSING PIPELINE                     │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐  │
│  │  Source  │    │Linearize │    │  Dither  │    │ Re-gamma │  │
│  │  Image   │───▶│ (γ^2.2)  │───▶│ (Linear) │───▶│ (γ^0.45) │  │
│  │ (sRGB)   │    │          │    │          │    │          │  │
│  └──────────┘    └──────────┘    └──────────┘    └──────────┘  │
│       │                                                │         │
│       │              GAMMA = 2.2                       │         │
│       ▼                                                ▼         │
│  ┌──────────┐                                   ┌──────────┐    │
│  │ 8-bit/ch │                                   │ RGB565   │    │
│  │ 0-255    │                                   │ 16-bit   │    │
│  └──────────┘                                   └──────────┘    │
│                                                       │         │
│                              ┌────────────────────────┘         │
│                              ▼                                  │
│                        ┌──────────┐                             │
│                        │  ST7789  │                             │
│                        │ Display  │                             │
│                        │ (γ=2.2)  │                             │
│                        └──────────┘                             │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Quick Reference Card

### SPI Configuration
```python
# Maximum SPI speed for ST7789VW
SPI_BAUDRATE = 40_000_000  # 40 MHz

# SPI mode
POLARITY = 0
PHASE = 0
```

### Color Conversion
```python
# RGB888 to RGB565
def rgb565(r, g, b):
    return ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3)

# Common colors
BLACK   = 0x0000
WHITE   = 0xFFFF
RED     = 0xF800
GREEN   = 0x07E0
BLUE    = 0x001F
YELLOW  = 0xFFE0
CYAN    = 0x07FF
MAGENTA = 0xF81F
```

### Gamma Commands
```python
# Set preset gamma
display._write_cmd_data(0x26, 0x01)  # γ=2.2

# Custom gamma (14 bytes each)
display._write_cmd(0xE0)  # Positive
display._write_data(positive_gamma_bytes)
display._write_cmd(0xE1)  # Negative
display._write_data(negative_gamma_bytes)
```

### Display Initialization Sequence
```
1. Hardware reset (RST low 10ms, high 120ms)
2. Software reset (0x01), wait 150ms
3. Sleep out (0x11), wait 120ms
4. Set color mode (0x3A, 0x55 for RGB565)
5. Set gamma (0x26, 0x01)
6. Set PVGAMCTRL (0xE0, 14 bytes)
7. Set NVGAMCTRL (0xE1, 14 bytes)
8. Inversion on (0x21) - if needed
9. Display on (0x29)
```

---

## Troubleshooting

### Colors Look Washed Out
- Check gamma preset is set to 0x01 (γ=2.2)
- Verify PVGAMCTRL and NVGAMCTRL values
- Try display inversion (0x21)

### Banding in Gradients
- Enable dithering in software
- Use Floyd-Steinberg for best quality
- Use ordered dithering for speed

### Image Appears Too Dark/Light
- Adjust gamma preset:
  - Too dark → Use 0x02 (γ=1.8)
  - Too light → Use 0x04 (γ=2.5)

### Color Channel Issues
- Enable digital gamma LUTs (0xBA)
- Adjust per-channel LUTs (0xE2 for red, 0xE3 for blue)

---

## Files Generated

1. **st7789vw_gamma_reference.md** - Full ST7789VW gamma datasheet extraction
2. **waveshare_esp32s3_lcd_gamma.md** - This file, board-specific implementation

Both files work together - the first provides the raw data, this one provides the practical implementation for your specific board.
