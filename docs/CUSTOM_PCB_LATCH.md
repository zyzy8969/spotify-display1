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

The firmware pin map is in `src/main.cpp` (lines 19–30). The custom board will use an ESP32-S3 module, so these are the signals it needs, not final GPIO numbers.

| Signal | Purpose | GPIO |
|---|---|---|
| BTN_IN | Power button input (INPUT_PULLUP, debounced) | TBD |
| LATCH_HOLD | Holds the power latch on; release to power off | TBD |
| TFT_BL | Backlight PWM | TBD (current firmware: 20) |
| TFT_RST / TFT_DC / TFT_CS / TFT_SCLK / TFT_MOSI | Display SPI | TBD (current firmware: 42 / 38 / 39 / 40 / 41) |
| SD_CS / SD_MISO / SD_MOSI / SD_CLK | SD card SPI | TBD (current firmware: 17 / 16 / 18 / 21) |
| VBAT_SENSE | Battery voltage ADC (optional v1) | TBD |
| USB D+ / D- | Programming (if the module exposes them) | TBD |

Avoid strapping pins GPIO0, GPIO3, GPIO45, GPIO46 for signals that must be stable at boot.

Pins can't be assigned until the module's datasheet is checked. The Waveshare pin table couldn't be fetched from this session.

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
