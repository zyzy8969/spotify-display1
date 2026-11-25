# Custom PCB: Power Latch Requirements

Status: planning. Pin assignments are TBD until the MCU module is chosen and the breadboard latch is validated.

## 1. Requirements

- Momentary button turns the device on (press) and off (long press).
- Device stays on after the button is released.
- Off state draws only microamps from the battery, so it holds charge on a shelf.
- Firmware performs a clean shutdown before the latch is released: disconnect BLE, close any open SD file.
- Single-cell LiPo: charging and over-discharge/over-current protection on the board.
- Display: 240x240 ST7789 SPI, backlight on PWM.
- SD card slot on a dedicated SPI bus (SD_CS, SD_MISO, SD_MOSI, SD_CLK).
- Battery voltage sense on an ADC pin (for a battery indicator; optional for v1).

## 2. Signals and pin plan

Source: the Waveshare ESP32-S3-R8 1.3" LCD pin sheet (project file). The firmware's pins in `src/main.cpp` match this sheet.

### Board pin map (from the Waveshare sheet)

| GPIO | Used for | Notes |
|---|---|---|
| 6 | VBAT_ADC | Battery voltage sense |
| 15 | RGB | Onboard RGB LED |
| 16 | SD_MISO | SD card |
| 17 | SD_CS | SD card |
| 18 | SD_MOSI | SD card |
| 19 | RST_Control | Board reset control, don't reuse |
| 20 | BL_PWM | Backlight PWM |
| 21 | SD_CLK | SD card |
| 38 | LCD DC | Display |
| 39 | LCD CS | Display |
| 40 | LCD CLK | Display |
| 41 | LCD MOSI | Display |
| 42 | LCD RES | Display reset |
| 43 | U0TXD | USB-serial chip (CH343P), don't reuse |
| 44 | U0RXD | USB-serial chip (CH343P), don't reuse |
| 45 | IMU_INT2 | QMI8658 IMU, strapping pin |
| 46 | IMU_INT1 | QMI8658 IMU, strapping pin |
| 47 | IMU_SDA | QMI8658 IMU (I2C) |
| 48 | IMU_SCL | QMI8658 IMU (I2C) |

**Broken out and unassigned ("OUT" column):** GPIO 1, 2, 3, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14.

**Unlisted on the sheet:** GPIO 0, 26, 33–37. Avoid these: GPIO0 is a boot strapping pin, and GPIO33–37 are typically used internally by the octal PSRAM on R8 parts (verify against the module datasheet).

### Proposed assignments for the latch (not yet validated)

| Signal | Proposed GPIO | Why |
|---|---|---|
| BTN_IN | 1 | Unassigned, not a strapping pin, RTC-capable (usable for deep-sleep wake) |
| LATCH_HOLD | 2 | Unassigned, not a strapping pin, RTC-capable |
| VBAT_SENSE | 6 | Already wired to the battery ADC on this board |

GPIO 3 is in the OUT column but is a strapping pin, so keep it off the button and latch.

Keeping the display, SD, IMU, and backlight on their current pins means the firmware needs no changes for the custom board.

## 3. Parts to buy (v1 prototype)

Verify each part's package, voltage, and current rating before ordering.

**Power latch**
- P-channel MOSFET for the latch. A forum builder used an IRLML6402 with a PMBT2369 NPN and reported it working with an ESP32.
- NPN transistor to drive the gate from LATCH_HOLD (for example, a 2N3904 or the PMBT2369 above).
- Resistors for the gate and base networks. Higher-value bias resistors cut standby current.
- Momentary tactile or panel-mount pushbutton (low profile for the enclosure).

**Power and charging**
- ESP32-S3 module (bare module, not a dev board).
- Single-cell LiPo charger IC with battery protection.
- LDO or buck regulator for 3.3 V (check quiescent current, since it sets standby draw).
- Decoupling capacitors per the module datasheet.
- Battery connector (JST-PH or similar) and the LiPo cell.

**Display and storage**
- 1.3" 240x240 ST7789 display module with an FPC or header connector.
- microSD slot (push-push type).

**Other**
- USB-C connector and ESD protection, if the module needs USB.
- Test points for battery voltage, 3.3 V rail, and quiescent current.
- Optional: QMI8658 IMU, if still wanted.

## 4. Before selling

- Shipping lithium batteries needs UN 38.3 test documentation.
- BLE radio needs certification (FCC for the US, CE for Europe).
- Battery safety standards apply. Check with a compliance consultant for your target market.

## 5. Order of work

1. Validate the latch on breadboard.
2. Confirm the firmware shutdown sequence on the dev board.
3. Choose the MCU module and assign pins from its datasheet.
4. Design the schematic, then the PCB layout.
5. Measure quiescent current on the first board before calling it done.
