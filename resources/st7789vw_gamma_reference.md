# ST7789VW Gamma & Color Reference for Python Projects

## Display Specifications
- **Resolution**: 240×240 (on 240×320 controller)
- **Frame Memory**: 240 × 320 × 18-bit = 1,382,400 bits
- **Max Colors**: 262,144 (18-bit RGB666)
- **Driver IC**: ST7789VW

---

## Color Depth Modes

| Mode | Bits/Pixel | Colors | COLMOD (3Ah) Value |
|------|------------|--------|-------------------|
| RGB 4-4-4 | 12-bit | 4,096 | 0x03 |
| RGB 5-6-5 | 16-bit | 65,536 | 0x05 |
| RGB 6-6-6 | 18-bit | 262,144 | 0x06 |

### RGB565 Bit Layout (Most Common for SPI)
```
Byte 1: RRRRRGGG
Byte 2: GGGBBBBB

R: bits 15-11 (5 bits) → 0-31
G: bits 10-5  (6 bits) → 0-63  
B: bits 4-0   (5 bits) → 0-31
```

### RGB666 Bit Layout (Internal Frame Memory)
```
R: 6 bits → 0-63
G: 6 bits → 0-63
B: 6 bits → 0-63
```

---

## Gamma Curve Selection (GAMSET Command 0x26)

| Parameter | Gamma Value | Description |
|-----------|-------------|-------------|
| 0x01 | γ ≈ 2.2 | **Default** - Standard sRGB |
| 0x02 | γ ≈ 1.8 | Lighter midtones |
| 0x04 | γ ≈ 2.5 | Darker midtones |
| 0x08 | γ ≈ 1.0 | Linear (no gamma) |

**Python usage:**
```python
def set_gamma_curve(spi, dc_pin, gamma=0x01):
    """
    Set preset gamma curve
    gamma: 0x01=2.2, 0x02=1.8, 0x04=2.5, 0x08=1.0
    """
    dc_pin.off()  # Command mode
    spi.write(bytes([0x26]))
    dc_pin.on()   # Data mode
    spi.write(bytes([gamma]))
```

---

## Gamma Voltage Reference Points

The ST7789VW uses 64 gray levels (V0-V63) for gamma correction.

### Reference Voltage Ranges
| Parameter | Description | Min | Max | Unit |
|-----------|-------------|-----|-----|------|
| VAP (GVDD) | Positive gamma reference | +4.45 | +6.4 | V |
| VAN (GVCL) | Negative gamma reference | -4.6 | -2.65 | V |

---

## Positive Voltage Gamma Control (PVGAMCTRL - 0xE0)

14 parameters control the positive polarity gamma curve:

| Param | Register | Gray Level | Bits | Range | Description |
|-------|----------|------------|------|-------|-------------|
| 1 | V63P | V63 | [3:0] | 0-15 | Highest brightness |
| 2 | V0P | V0 | [3:0] | 0-15 | Lowest brightness |
| 3 | V1P | V1 | [5:0] | 0-63 | |
| 4 | V2P | V2 | [5:0] | 0-63 | |
| 5 | V4P | V4 | [4:0] | 0-31 | |
| 6 | V6P | V6 | [4:0] | 0-31 | |
| 7 | V13P | V13 | [3:0] | 0-15 | |
| 8 | V20P | V20 | [6:0] | 0-127 | **Mid gray point** |
| 9 | V27P | V27 | [2:0] | 0-7 | |
| 10 | V36P | V36 | [2:0] | 0-7 | |
| 11 | V43P | V43 | [6:0] | 0-127 | **Mid gray point** |
| 12 | V50P | V50 | [3:0] | 0-15 | |
| 13 | V57P | V57 | [4:0] | 0-31 | |
| 14 | V59P | V59 | [4:0] | 0-31 | |

### Byte Format for PVGAMCTRL (0xE0)
```
Byte 1:  [D7:D4]=V63P[3:0], [D3:D0]=V0P[3:0]
Byte 2:  [D5:0]=V1P[5:0]
Byte 3:  [D5:0]=V2P[5:0]
Byte 4:  [D4:0]=V4P[4:0]
Byte 5:  [D4:0]=V6P[4:0]
Byte 6:  [D7:D4]=J0P[1:0], [D3:0]=V13P[3:0]
Byte 7:  [D6:0]=V20P[6:0]
Byte 8:  [D6:D4]=V36P[2:0], [D2:0]=V27P[2:0]
Byte 9:  [D6:0]=V43P[6:0]
Byte 10: [D7:D4]=J1P[1:0], [D3:0]=V50P[3:0]
Byte 11: [D4:0]=V57P[4:0]
Byte 12: [D4:0]=V59P[4:0]
Byte 13: [D5:0]=V61P[5:0]
Byte 14: [D5:0]=V62P[5:0]
```

---

## Negative Voltage Gamma Control (NVGAMCTRL - 0xE1)

Same 14 parameters for negative polarity (inverted frame):

| Param | Register | Gray Level | Bits | Range |
|-------|----------|------------|------|-------|
| 1 | V63N | V63 | [3:0] | 0-15 |
| 2 | V0N | V0 | [3:0] | 0-15 |
| 3 | V1N | V1 | [5:0] | 0-63 |
| 4 | V2N | V2 | [5:0] | 0-63 |
| 5 | V4N | V4 | [4:0] | 0-31 |
| 6 | V6N | V6 | [4:0] | 0-31 |
| 7 | V13N | V13 | [3:0] | 0-15 |
| 8 | V20N | V20 | [6:0] | 0-127 |
| 9 | V27N | V27 | [2:0] | 0-7 |
| 10 | V36N | V36 | [2:0] | 0-7 |
| 11 | V43N | V43 | [6:0] | 0-127 |
| 12 | V50N | V50 | [3:0] | 0-15 |
| 13 | V57N | V57 | [4:0] | 0-31 |
| 14 | V59N | V59 | [4:0] | 0-31 |

---

## Gamma Voltage Formulas

### Positive Gamma (Source Output)

```python
# Key voltage calculations for positive gamma
# R = internal resistance unit

def calc_vp0(V0P, VAP, VBP):
    """V0 - Lowest brightness"""
    return (VAP - VBP) * (129 - V0P) / 129 + VBP

def calc_vp63(V63P, VAP, VBP):
    """V63 - Highest brightness"""  
    return (VAP - VBP) * (23 - V63P) / 129 + VBP

def calc_vp20(V20P, VAP, VBP):
    """V20 - Key midpoint"""
    return (VAP - VBP) * (128 - V20P) / 129 + VBP

def calc_vp43(V43P, VAP, VBP):
    """V43 - Key midpoint"""
    return (VAP - VBP) * (128 - V43P) / 129 + VBP
```

### Interpolated Points (J0P/J1P Percentage Tables)

**J0P[1:0] controls interpolation for V3, V5, V7-V12:**

| J0P | V3/V5 | V7 | V8 | V9 | V10 | V11 | V12 |
|-----|-------|----|----|----|----|-----|-----|
| 00 | 50% | 86% | 71% | 57% | 43% | 29% | 14% |
| 01 | 56%/44% | 71% | 57% | 40% | 29% | 17% | 6% |
| 02 | 50% | 80% | 63% | 49% | 34% | 20% | 9% |
| 03 | 60%/42% | 66% | 49% | 34% | 23% | 14% | 6% |

**J1P[1:0] controls interpolation for V51-V56, V58, V60:**

| J1P | V51 | V52 | V53 | V54 | V55 | V56 | V58 | V60 |
|-----|-----|-----|-----|-----|-----|-----|-----|-----|
| 00 | 86% | 71% | 57% | 43% | 29% | 14% | 50% | 50% |
| 01 | 86% | 71% | 60% | 46% | 34% | 17% | 56% | 50% |
| 02 | 86% | 77% | 63% | 46% | 31% | 14% | 47% | 50% |
| 03 | 89% | 80% | 69% | 51% | 37% | 20% | 47% | 53% |

---

## Digital Gamma Enable (DGMEN - 0xBA)

Enables per-channel digital gamma correction:

```python
def enable_digital_gamma(spi, dc_pin, enable=True):
    """Enable/disable digital gamma LUTs for R/B channels"""
    dc_pin.off()
    spi.write(bytes([0xBA]))
    dc_pin.on()
    spi.write(bytes([0x04 if enable else 0x00]))
```

---

## Digital Gamma Look-Up Tables

### Red Channel LUT (DGMLUTR - 0xE2)
- 64 bytes, one per gray level (0-63)
- Maps input gray level to output gray level

### Blue Channel LUT (DGMLUTB - 0xE3)  
- 64 bytes, one per gray level (0-63)
- Maps input gray level to output gray level

**Note:** Green channel uses the analog gamma curve directly.

```python
def set_red_gamma_lut(spi, dc_pin, lut):
    """
    Set 64-byte red channel gamma LUT
    lut: list of 64 values (0-63 each)
    """
    dc_pin.off()
    spi.write(bytes([0xE2]))
    dc_pin.on()
    spi.write(bytes(lut))

def set_blue_gamma_lut(spi, dc_pin, lut):
    """
    Set 64-byte blue channel gamma LUT
    lut: list of 64 values (0-63 each)
    """
    dc_pin.off()
    spi.write(bytes([0xE3]))
    dc_pin.on()
    spi.write(bytes(lut))
```

---

## Common Gamma Settings for Different Use Cases

### Default γ=2.2 (sRGB Standard)
```python
# Typical values for γ=2.2
PVGAMCTRL_DEFAULT = [
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
]

NVGAMCTRL_DEFAULT = [
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
]
```

### Linear γ=1.0 (No Gamma Correction)
```python
# For linear response - useful for image processing
def generate_linear_lut():
    """Generate linear 1:1 mapping LUT"""
    return list(range(64))
```

---

## Python Implementation for Dithering with Gamma

### Software Gamma Correction Before Dithering

```python
import math

def create_gamma_lut(gamma=2.2, bits_in=8, bits_out=6):
    """
    Create gamma correction lookup table
    
    Args:
        gamma: Target gamma value (2.2 for sRGB)
        bits_in: Input bit depth (8 for standard images)
        bits_out: Output bit depth (6 for ST7789VW internal)
    
    Returns:
        list: 256-entry LUT mapping 8-bit to 6-bit with gamma
    """
    max_in = (1 << bits_in) - 1    # 255
    max_out = (1 << bits_out) - 1  # 63
    
    lut = []
    for i in range(max_in + 1):
        # Normalize to 0-1
        normalized = i / max_in
        # Apply gamma
        corrected = math.pow(normalized, gamma)
        # Scale to output range
        output = int(round(corrected * max_out))
        lut.append(min(max_out, max(0, output)))
    
    return lut

def create_inverse_gamma_lut(gamma=2.2, bits_in=8):
    """
    Create inverse gamma LUT (for linearizing sRGB input)
    Use this BEFORE dithering for best results
    """
    max_val = (1 << bits_in) - 1
    lut = []
    for i in range(max_val + 1):
        normalized = i / max_val
        # Remove gamma (linearize)
        linear = math.pow(normalized, gamma)
        lut.append(linear)
    return lut

def create_gamma_encode_lut(gamma=2.2, bits_out=6):
    """
    Create gamma encoding LUT (for applying gamma after dithering)
    """
    max_out = (1 << bits_out) - 1
    lut = []
    for i in range(256):  # Assuming 8-bit linear input
        normalized = i / 255.0
        # Apply inverse gamma (encode)
        encoded = math.pow(normalized, 1.0 / gamma)
        output = int(round(encoded * max_out))
        lut.append(min(max_out, max(0, output)))
    return lut
```

### RGB565 Conversion with Gamma

```python
def rgb888_to_rgb565_gamma(r, g, b, gamma_lut_r, gamma_lut_g, gamma_lut_b):
    """
    Convert RGB888 to RGB565 with gamma-aware quantization
    
    Args:
        r, g, b: 8-bit color values (0-255)
        gamma_lut_*: Pre-computed gamma LUTs
    
    Returns:
        tuple: (high_byte, low_byte) for SPI transfer
    """
    # Apply gamma correction
    r_corrected = gamma_lut_r[r]
    g_corrected = gamma_lut_g[g]
    b_corrected = gamma_lut_b[b]
    
    # Quantize to RGB565
    r5 = (r_corrected >> 3) & 0x1F  # 5 bits
    g6 = (g_corrected >> 2) & 0x3F  # 6 bits
    b5 = (b_corrected >> 3) & 0x1F  # 5 bits
    
    # Pack into 16-bit value
    rgb565 = (r5 << 11) | (g6 << 5) | b5
    
    return (rgb565 >> 8) & 0xFF, rgb565 & 0xFF
```

### Floyd-Steinberg Dithering with Gamma Awareness

```python
def dither_image_gamma_aware(image, gamma=2.2):
    """
    Floyd-Steinberg dithering with proper gamma handling
    
    For best results:
    1. Linearize input (remove gamma)
    2. Dither in linear space  
    3. Re-apply gamma for display
    
    Args:
        image: numpy array (H, W, 3) with values 0-255
        gamma: Display gamma (2.2 for sRGB)
    
    Returns:
        numpy array: Dithered image for RGB565
    """
    import numpy as np
    
    h, w, _ = image.shape
    
    # Step 1: Linearize (remove sRGB gamma)
    linear = np.power(image / 255.0, gamma)
    
    # Work in higher precision
    img = (linear * 255.0).astype(np.float32)
    
    # Target levels for RGB565: R=32, G=64, B=32
    levels_r = 32
    levels_g = 64
    levels_b = 32
    
    for y in range(h):
        for x in range(w):
            old_r, old_g, old_b = img[y, x]
            
            # Quantize to target levels
            new_r = round(old_r * (levels_r - 1) / 255) * 255 / (levels_r - 1)
            new_g = round(old_g * (levels_g - 1) / 255) * 255 / (levels_g - 1)
            new_b = round(old_b * (levels_b - 1) / 255) * 255 / (levels_b - 1)
            
            img[y, x] = [new_r, new_g, new_b]
            
            # Calculate error
            err_r = old_r - new_r
            err_g = old_g - new_g
            err_b = old_b - new_b
            
            # Distribute error (Floyd-Steinberg coefficients)
            if x + 1 < w:
                img[y, x + 1] += [err_r * 7/16, err_g * 7/16, err_b * 7/16]
            if y + 1 < h:
                if x > 0:
                    img[y + 1, x - 1] += [err_r * 3/16, err_g * 3/16, err_b * 3/16]
                img[y + 1, x] += [err_r * 5/16, err_g * 5/16, err_b * 5/16]
                if x + 1 < w:
                    img[y + 1, x + 1] += [err_r * 1/16, err_g * 1/16, err_b * 1/16]
    
    # Step 3: Re-apply gamma for display
    img = np.clip(img, 0, 255)
    output = np.power(img / 255.0, 1.0 / gamma) * 255.0
    
    return output.astype(np.uint8)
```

---

## Hardware Gamma Commands Summary

| Command | Hex | Parameters | Description |
|---------|-----|------------|-------------|
| GAMSET | 0x26 | 1 byte | Select preset gamma curve |
| DGMEN | 0xBA | 1 byte | Enable digital gamma |
| PVGAMCTRL | 0xE0 | 14 bytes | Positive voltage gamma |
| NVGAMCTRL | 0xE1 | 14 bytes | Negative voltage gamma |
| DGMLUTR | 0xE2 | 64 bytes | Red digital gamma LUT |
| DGMLUTB | 0xE3 | 64 bytes | Blue digital gamma LUT |

---

## Initialization Sequence with Gamma

```python
def init_display_with_gamma(spi, dc_pin, rst_pin):
    """Complete initialization including gamma setup"""
    
    # Hardware reset
    rst_pin.off()
    time.sleep_ms(10)
    rst_pin.on()
    time.sleep_ms(120)
    
    # Software reset
    send_cmd(spi, dc_pin, 0x01)
    time.sleep_ms(120)
    
    # Sleep out
    send_cmd(spi, dc_pin, 0x11)
    time.sleep_ms(120)
    
    # Color mode: RGB565
    send_cmd(spi, dc_pin, 0x3A, [0x55])
    
    # Select gamma curve (γ=2.2)
    send_cmd(spi, dc_pin, 0x26, [0x01])
    
    # Positive gamma
    send_cmd(spi, dc_pin, 0xE0, [
        0xD0, 0x04, 0x0D, 0x11, 0x13, 0x2B, 0x3F,
        0x54, 0x4C, 0x18, 0x0D, 0x0B, 0x1F, 0x23
    ])
    
    # Negative gamma
    send_cmd(spi, dc_pin, 0xE1, [
        0xD0, 0x04, 0x0C, 0x11, 0x13, 0x2C, 0x3F,
        0x44, 0x51, 0x2F, 0x1F, 0x1F, 0x20, 0x23
    ])
    
    # Display on
    send_cmd(spi, dc_pin, 0x29)
    time.sleep_ms(20)

def send_cmd(spi, dc_pin, cmd, data=None):
    """Send command with optional data"""
    dc_pin.off()
    spi.write(bytes([cmd]))
    if data:
        dc_pin.on()
        spi.write(bytes(data))
```

---

## Key Points for Your Dithering Implementation

1. **Display assumes γ=2.2 by default** - Input images in sRGB are already gamma-encoded

2. **For best dithering results:**
   - Linearize image first (decode gamma)
   - Perform dithering in linear space
   - Re-encode gamma before sending to display

3. **RGB565 quantization losses:**
   - Red: 8-bit → 5-bit (lose 3 bits)
   - Green: 8-bit → 6-bit (lose 2 bits)
   - Blue: 8-bit → 5-bit (lose 3 bits)

4. **Internal storage is 18-bit (RGB666)** even when using 16-bit interface

5. **Digital gamma LUTs** only affect R and B channels - useful for color calibration

---

## References

- ST7789VW Datasheet v1.0 (2017/09) - Sitronix Technology Corporation
- Sections: 8.19 (Gamma Correction), 8.20 (Digital Gamma), 9.2.26-9.2.29 (Commands)
