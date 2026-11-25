# Project handoff — Spotify Display (2026-11-25)

Paste this into a new chat, or point the new session at this file. Repo: `zyzy8969/spotify-display1`, branch `claude/sweet-johnson-usmhyq`.

## 1. What the product is

A standalone "now playing" display. An iPhone app reads the current Spotify track, downloads the album art, converts it to 240×240 RGB565, and sends it over BLE to an ESP32-S3 board with a 1.3" ST7789 screen. The board caches art on a microSD card. Longer-term goal: a sellable product, possibly on a custom PCB, in a custom enclosure.

## 2. Hardware

- **Board:** Waveshare ESP32-S3-R8 1.3" LCD (240×240 ST7789). Firmware in `src/main.cpp`, built with PlatformIO (`platformio.ini`, env `esp32-s3-devkitc-1`).
- **Pin map (from the Waveshare pin sheet; matches firmware):**
  - Display: DC 38, CS 39, CLK 40, MOSI 41, RES 42, backlight PWM (BL_PWM) 20.
  - SD (dedicated SPI): CS 17, MISO 16, MOSI 18, CLK 21.
  - Battery ADC (VBAT_ADC): 6.
  - Reserved, don't reuse: RST_Control 19; USB-serial U0TXD 43 / U0RXD 44; IMU QMI8658 INT2 45, INT1 46, SDA 47, SCL 48.
  - Broken out and unassigned ("OUT"): GPIO 1, 2, 3, 4, 5, 7, 8, 9, 10, 11, 12, 13, 14.
  - Avoid: GPIO 0 (boot strapping), and 26, 33–37 (typically internal PSRAM on R8 parts; verify against the module datasheet).
  - Note: `resources/waveshare_esp32s3_lcd_gamma.md` has a 12-pin table with placeholder GPIOs (4–9) that conflict with the pin sheet. Treat the pin sheet as authoritative and that table as wrong.
- **Power:** a battery input with a VBAT_ADC sense line. No on/off control yet.
- **Storage:** microSD card for art cache. The firmware starts at 25 MHz and falls back to 10 MHz if init fails.

## 3. Software status

**Firmware (`src/main.cpp`)** — per the April docs:
- Cache upgrade (in-memory index, atomic writes, CRC validation and recovery, deterministic clear, telemetry).
- Disconnect recovery is consolidated in `loop()`.
- A brightness BLE characteristic exists (`0000ffe5-…`). The roadmap still lists it as to-do, so verify the iOS side.
- Protocol contract: `docs/BLE_PROTOCOL.md`.

**iOS app (`SpotifyDisplay.swiftpm/`, `ios/`):**
- Background BLE (`bluetooth-central`, state restoration) and a display-failure cooldown are in, per `docs/DEV_HANDOFF.md`.
- Build only in Xcode on a Mac; `swift build` from the terminal can fail in sandboxed environments.

## 4. Open issues (from `PROJECT_STATUS.md`, April, unverified since)

1. Cover art resizes during download, then snaps back.
2. App layout doesn't fill the screen consistently (`AlbumArtView` in `ContentView.swift`).
3. Intermittent skip-render artifact: the previous image can flash after a skip or reconnect. Root cause unknown.
4. Dithering is a no-op: Floyd-Steinberg runs on already-quantized data. Plan: dither during quantization or switch to Atkinson.
5. Color grading and gamma need a datasheet review.
6. Background behavior: Spotify polling stops when the phone is locked, so the display goes stale. Needs a real design decision.
7. Album-ID cache key instead of a hash of the image URL.
8. Transition effects and the UI redesign.
9. Later: GIF support and custom image upload.

## 5. New items (added 2026-11-25, in `TODO_SWIFT.md`)

- **Power latch on breadboard.** Momentary button + P-MOSFET latch. Button press turns on; the firmware holds the latch; long press releases it to turn off.
- **Firmware clean shutdown.** On off-press: disconnect BLE, close any open SD file, then release the latch.
- **Custom PCB with the latch.** Bare ESP32-S3 module, LiPo charger with protection, latch, quiescent-current test point. Details in `docs/CUSTOM_PCB_LATCH.md`.
- **Album color mode (toggle in app).** When on, after the art finishes downloading, the display shows a solid color closest to the album cover's dominant color. When off, normal art. Open question: compute the color on the phone and send one color over BLE (leaning this way), or average the RGB565 buffer in firmware.

### Proposed latch GPIOs (not validated)
- Button: GPIO 1 (RTC-capable, so it can wake from deep sleep).
- Latch hold: GPIO 2.
- Battery sense: GPIO 6.

## 6. Power decision

Use a soft power latch, not a slide switch or deep sleep alone. Deep sleep still draws current and drains the battery; a slide switch works for a prototype but isn't a product feel. The latch needs a P-MOSFET and an NPN driven from a GPIO. A forum builder reported IRLML6402 + PMBT2369 working on an ESP32. Watch for the gate lagging at power-up, and check the gate voltage when the button is pressed.

## 7. Enclosure

- **Source:** Fusion 360 archive `shell C` (`.f3d`, uploaded) and its STL export (`shell C.stl`, uploaded).
- **Measured from the STL (assumed mm):** 29.75 × 32.72 × 22.00 mm, 9,336 triangles.
- **Fit concern:** the display's active area is 23.4 mm square. With a 29.75 mm width, there's only about 3 mm each side for bezel, board, and walls. Check against the board's mechanical drawing before going further.
- **Not visible in the mesh:** magnet pocket on the back, keychain loop, display window, button opening. Preview shows a top oval recess (possibly a handle or keyring slot) and a vent grille on one side. The top-view oval is unconfirmed.
- **Design goals:** magnetic back (phone or headphones) and keychain loop, both in one enclosure.

## 8. Buying and compliance (v1 prototype)

- **Latch:** P-MOSFET (IRLML6402 used by a forum builder), NPN (2N3904 or PMBT2369), resistors, a low-profile tactile or panel-mount button.
- **Power:** bare ESP32-S3 module (for the custom PCB), single-cell LiPo charger with protection, 3.3 V LDO or buck (check quiescent current), decoupling caps, JST-PH connector, LiPo cell.
- **Display and storage:** 1.3" 240×240 ST7789 module with FPC or header, push-push microSD slot.
- **Other:** USB-C with ESD protection if needed, test points for battery voltage, 3.3 V rail, and quiescent current. Optional QMI8658 IMU.
- **Before selling:** UN 38.3 for shipping lithium batteries; FCC (US) and CE (EU) for BLE radio; battery safety standards. Consult a compliance specialist for the target market.

## 9. Known gaps and open questions

- The April status docs may be stale. Check recent commits before trusting them.
- The pin sheet was shared as an image in chat and isn't stored in the repo. Its pin map is copied into `docs/CUSTOM_PCB_LATCH.md` and section 2 above.
- Waveshare website not reachable from the work sessions, so the board's mechanical drawing and schematic weren't checked.
- Enclosure dimensions vs. board size: unresolved.
- Whether `shell C` is the design to keep, or a variant to compare.
- Is the display's screen face front or back in the enclosure? Not confirmed.
- Who is building the custom PCB, and when?

## 10. Suggested first steps for the new session

1. Confirm the board's mechanical drawing and check whether `shell C` fits it.
2. Build and run the power latch on breadboard, using GPIO 1 and 2.
3. Implement firmware clean shutdown.
4. Decide where the album color is computed (phone vs. firmware) and write it into `docs/BLE_PROTOCOL.md` before coding.
5. Fix the dithering no-op (item 4 above) and the cover-art resize (item 1) in the iOS app.
