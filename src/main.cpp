// ESP32 Album Art Display - Arduino_GFX Version
// Receives and displays RGB565 images from Python via Bluetooth LE
// Repo: spotify-display1 — BLE GATT contract: docs/BLE_PROTOCOL.md (keep in sync with Python + iOS)

#include <Arduino_GFX_Library.h>
#include <SD.h>
#include <FS.h>
#include <SPI.h>

// Bluetooth LE includes
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

// Pin definitions for Waveshare ESP32-S3 1.3" LCD
#define TFT_BL 20
#define TFT_RST 42
#define TFT_DC 38
#define TFT_CS 39
#define TFT_MOSI 41
#define TFT_SCLK 40

// SD Card pins (dedicated SPI bus, separate from display)
#define SD_CS 17
#define SD_MISO 16
#define SD_MOSI 18
#define SD_CLK 21

#define DISPLAY_WIDTH 240
#define DISPLAY_HEIGHT 240
#define IMAGE_SIZE (DISPLAY_WIDTH * DISPLAY_HEIGHT * 2)

// Performance and timing constants
#define TFT_BRIGHTNESS_MAX 200
#define TRANSITION_WIPE_DELAY_US 500
#define CIRCULAR_WIPE_MAX_RADIUS 170

// Create display bus and display objects with higher SPI frequency
Arduino_DataBus *bus = new Arduino_ESP32SPI(TFT_DC, TFT_CS, TFT_SCLK, TFT_MOSI, 1 /* MISO */, FSPI /* spi_num */, 80000000 /* freq 80MHz */);
// ST7789VW chip - using IPS=true (enable color inversion for correct colors)
Arduino_GFX *gfx = new Arduino_ST7789(bus, TFT_RST, 0 /* rotation */, true /* IPS */, 240, 240, 0, 0);

// Brightness control - maximum for vibrant display
// ST7789VW spec: 250 cd/m² typical luminance, 800:1 contrast ratio
int brightness = TFT_BRIGHTNESS_MAX;  // 100% brightness for maximum vibrancy

// Pre-allocated image buffer (prevents heap fragmentation)
static uint16_t* imageBuffer = nullptr;

// ==================================================
// BLUETOOTH LE CONFIGURATION
// ==================================================

// BLE Service and Characteristic UUIDs
#define SERVICE_UUID        "0000ffe0-0000-1000-8000-00805f9b34fb"
#define STATUS_CHAR_UUID    "0000ffe1-0000-1000-8000-00805f9b34fb"
#define CACHE_CHAR_UUID     "0000ffe2-0000-1000-8000-00805f9b34fb"
#define IMAGE_CHAR_UUID     "0000ffe3-0000-1000-8000-00805f9b34fb"
#define MESSAGE_CHAR_UUID   "0000ffe4-0000-1000-8000-00805f9b34fb"

// BLE Server and Characteristics
BLEServer* pServer = nullptr;
BLECharacteristic* pStatusChar = nullptr;
BLECharacteristic* pCacheChar = nullptr;
BLECharacteristic* pImageChar = nullptr;
BLECharacteristic* pMsgChar = nullptr;

// BLE Connection state
bool deviceConnected = false;
bool oldDeviceConnected = false;

// Spotify brand color (vibrant dark green)
#define SPOTIFY_GREEN 0x064C  // RGB565(0, 200, 100) - vibrant dark green

// Image transfer state
enum ImageState {
    WAITING_FOR_SIZE,
    RECEIVING_DATA,
    COMPLETE
};

ImageState imageState = WAITING_FOR_SIZE;
uint32_t expectedSize = 0;
uint32_t receivedBytes = 0;
uint8_t currentCacheKey[16];
bool cacheHit = false;

// Transition effects enum
enum TransitionType {
  TRANSITION_WIPE_BOTTOM,     // Bottom to top
  TRANSITION_WIPE_LEFT,       // Left to right
  TRANSITION_WIPE_RIGHT,      // Right to left
  TRANSITION_CIRCULAR,        // Expand from center
  TRANSITION_CHECKERBOARD,    // Dissolve pattern
  TRANSITION_SLIDE_REVEAL,    // Slide reveal
  TRANSITION_DIAGONAL,        // Diagonal wipe
  TRANSITION_DIAGONAL_INVERSE,  // Diagonal wipe (bottom-right to top-left)
  TRANSITION_VENETIAN_V,      // Venetian blinds vertical
  TRANSITION_FOUR_CORNER,     // Wipe from all 4 corners
  TRANSITION_CURTAIN,         // Curtain open from center
  TRANSITION_ZOOM_BLOCKS,     // Zoom from center outward
  TRANSITION_HORIZONTAL_SPLIT, // Split from center horizontally
  TRANSITION_VERTICAL_SPLIT,  // Split from center vertically
  TRANSITION_BARN_DOORS,      // Barn doors open from center
  TRANSITION_RANDOM_BLOCKS,   // Random block reveal
  TRANSITION_ZIGZAG_SNAKE,    // Zigzag top/bottom reveal
  TRANSITION_COUNT            // Total number of transitions
};

// Track last transition to avoid repeats
static TransitionType lastTransition = TRANSITION_COUNT;  // Invalid value initially

// Forward declarations
void flushSerialInput();
void printCardInfo();
void testFileOperations();
void showTroubleshooting();
bool isCached(uint8_t* cacheKey);
bool loadFromCache(uint8_t* cacheKey);
bool saveToCache(uint8_t* cacheKey);
void printRainbowText(String text, int x, int y, int textSize);
void applyFloydSteinbergDithering(uint16_t* buffer, int width, int height);
void showBluetoothConnectionScreen(uint16_t yesColor, uint16_t noColor);
void drawZoomBlocks(uint16_t* buffer, int width, int height);

// BLE work flags (set by callbacks, processed in loop())
// CRITICAL: Callbacks must be lightweight to prevent BTC_TASK stack overflow
volatile bool cacheCheckPending = false;
volatile bool statsRequestPending = false;
volatile bool imageTransferComplete = false;
volatile uint32_t lastDrawnBytes = 0;  // Track how many bytes we've drawn so far

// Rainbow text animation state
int currentRainbowIndex = 0;
unsigned long lastRainbowUpdate = 0;
const unsigned long rainbowUpdateInterval = 200; // Update every 150ms (smooth wave speed)
bool showingStartupScreen = true;

// Pulsing "no" animation state
unsigned long lastPulseUpdate = 0;
const unsigned long pulseUpdateInterval = 500; // Toggle every 500ms
bool pulseIsWhite = false; // Toggle between red and white

// ==================================================
// BLUETOOTH LE CALLBACK CLASSES
// ==================================================

// Decode 4 bytes from a BLE value string as a little-endian uint32
inline uint32_t decodeLE32(const std::string& value) {
    return (uint8_t)value[0]
         | ((uint8_t)value[1] << 8)
         | ((uint8_t)value[2] << 16)
         | ((uint8_t)value[3] << 24);
}

// Server callbacks - handle connection/disconnection events
class MyServerCallbacks: public BLEServerCallbacks {
    void onConnect(BLEServer* pServer) {
        deviceConnected = true;
        Serial.println("BLE Client connected");

        // Update to connected state (yes=green, no=black - connected!)
        showingStartupScreen = false;
        showBluetoothConnectionScreen(GREEN, BLACK);

        // Clear and show ready message - LARGER & CENTERED
        gfx->fillScreen(WHITE);
        gfx->setTextSize(3);  // Increased from 2 to 3
        gfx->setTextColor(BLACK);
        gfx->setCursor(39, 80);  // Centered: "Play some" = 9 chars
        gfx->print("Play some");
        gfx->setCursor(48, 110);  // Centered: "music on" = 8 chars
        gfx->print("music on");
        gfx->setCursor(48, 140);  // Centered: "Spotify!" = 8 chars
        gfx->setTextColor(SPOTIFY_GREEN); // Darker Spotify green
        gfx->print("Spotify!");

        // Get negotiated MTU size
        uint16_t mtu = pServer->getPeerMTU(pServer->getConnId());
        Serial.printf("BLE: Negotiated MTU = %d bytes\n", mtu);

        if (mtu < 200) {
            Serial.println("WARNING: MTU negotiation may have failed! Expected 517, got " + String(mtu));
            Serial.println("Performance will be degraded. Check client MTU request.");
        }

        // Notify client we're ready
        uint8_t ready = 0x01;
        pStatusChar->setValue(&ready, 1);
        pStatusChar->notify();

        // Send READY message
        pMsgChar->setValue("READY");
        pMsgChar->notify();
        Serial.println("BLE: Sent READY signal");
    }

    void onDisconnect(BLEServer* pServer) {
        deviceConnected = false;
        Serial.println("BLE Client disconnected");

        // Return to waiting state (yes=black, no=red)
        showBluetoothConnectionScreen(BLACK, RED);

        showingStartupScreen = true;
        Serial.println("Display reset to waiting state");

        // Restart advertising
        pServer->startAdvertising();
        Serial.println("BLE Advertising restarted");
    }
};

// Cache check callbacks - handle cache validation requests
// LIGHTWEIGHT: Only stores data and sets flag, returns immediately
class CacheCheckCallbacks: public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pCharacteristic) {
        std::string value = pCharacteristic->getValue();

        if (value.length() != 20) {
            Serial.printf("ERROR: Cache check got %d bytes, expected 20\n", value.length());
            return;
        }

        uint32_t magic = decodeLE32(value);

        // Stats request (iOS app): same 20-byte write, magic + padding — no cache key
        if (magic == 0xC0FFEEE1) {
            statsRequestPending = true;
            return;
        }

        if (magic != 0xDEADBEEF) {
            Serial.printf("ERROR: Bad magic 0x%08X\n", magic);
            return;
        }

        // Extract and store cache key (next 16 bytes)
        memcpy(currentCacheKey, value.data() + 4, 16);

        // Set flag for loop() to process
        // CRITICAL: Don't do SD card/display work here - BTC_TASK stack is tiny!
        cacheCheckPending = true;

        // Return immediately - let loop() do the heavy work
    }
};

// Image transfer callbacks - handle image data reception
// LIGHTWEIGHT: Only receives data and sets flag, heavy work done in loop()
class ImageTransferCallbacks: public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pCharacteristic) {
        std::string value = pCharacteristic->getValue();

        if (imageState == WAITING_FOR_SIZE) {
            // First write should be 4-byte size header
            if (value.length() != 4) {
                Serial.printf("ERROR: Expected 4-byte size, got %d\n", value.length());
                return;
            }

            expectedSize = decodeLE32(value);

            if (expectedSize != IMAGE_SIZE) {
                Serial.printf("ERROR: Size mismatch, got %d, expected %d\n",
                              expectedSize, IMAGE_SIZE);
                pMsgChar->setValue("ERROR: Size mismatch");
                pMsgChar->notify();
                imageState = WAITING_FOR_SIZE;  // Reset
                return;
            }

            Serial.printf("BLE: Expecting %d bytes\n", expectedSize);
            receivedBytes = 0;
            imageState = RECEIVING_DATA;

        } else if (imageState == RECEIVING_DATA) {
            // New image header mid-stream: client cancelled and started a fresh transfer
            if (value.length() == 4 && decodeLE32(value) == IMAGE_SIZE) {
                Serial.println("BLE: Image header (resync) — discarding partial frame");
                receivedBytes = 0;
                return;
            }

            // Subsequent writes are image data chunks
            size_t chunkSize = value.length();

            if (receivedBytes + chunkSize > expectedSize) {
                Serial.println("ERROR: Buffer overflow");
                pMsgChar->setValue("ERROR: Buffer overflow");
                pMsgChar->notify();
                imageState = WAITING_FOR_SIZE;  // Reset
                receivedBytes = 0;
                return;
            }

            // Copy chunk to image buffer (memcpy is fast, safe in callback)
            memcpy((uint8_t*)imageBuffer + receivedBytes, value.data(), chunkSize);
            receivedBytes += chunkSize;

            // Log progress (every 10KB or final)
            if (receivedBytes % 10240 == 0 || receivedBytes == expectedSize) {
                uint8_t progress = (receivedBytes * 100) / expectedSize;
                Serial.printf("BLE Progress: %d%%\n", progress);
            }

            // Check if complete
            if (receivedBytes == expectedSize) {
                Serial.println("BLE: Image transfer complete");

                // Set flag for loop() to handle display/save
                // CRITICAL: Don't do display/SD card work here - BTC_TASK stack is tiny!
                imageTransferComplete = true;

                // Reset state immediately to prevent buffer overflow from late chunks
                imageState = WAITING_FOR_SIZE;
                receivedBytes = 0;
                expectedSize = 0;

                // Return immediately - let loop() do the heavy work
            }
        }
    }
};

// ==================================================
// RAINBOW TEXT HELPER
// ==================================================

// Rainbow color palette (RGB565)
uint16_t rainbowColors[] = {
  0xF800,    // Red
  0xFA00,    // Red-Orange
  0xFC00,    // Orange-Red
  0xFD20,    // Orange
  0xFE60,    // Light Orange
  0xFEA0,    // Yellow-Orange
  0xFFE0,    // Yellow
  0xDFE0,    // Yellow-Lime
  0xAFE5,    // Yellow-Green (Lime)
  0x5FE8,    // Lime-Green
  0x07E0,    // Green
  0x07E8,    // Green-Cyan
  0x07EF,    // Cyan-Green
  0x07F7,    // Light Cyan
  0x07FF,    // Cyan
  0x041F,    // Sky Blue
  0x021F,    // Light Blue
  0x001F,    // Blue
  0x2010,    // Blue-Indigo
  0x4810,    // Indigo
  0x6810,    // Deep Indigo
  0x780F,    // Deep Purple
  0xA00F,    // Purple
  0xF81F,    // Magenta
  0xFC1F,    // Pink
  0xF81A,    // Hot Pink
};

// Function to print text with rainbow colors
void printRainbowText(String text, int x, int y, int textSize) {
  int colorIndex = 0;  // Start with the first color in the array
  gfx->setTextSize(textSize);  // Set the text size

  // Loop through each character in the string and apply a different color
  for (int i = 0; i < text.length(); i++) {
    gfx->setTextColor(rainbowColors[colorIndex]);  // Set the color for the character
    gfx->setCursor(x + i * (6 * textSize), y);  // Adjust horizontal position based on character width
    gfx->print(text.charAt(i));  // Print the character

    // Move to the next color in the rainbow
    colorIndex++;
    if (colorIndex >= sizeof(rainbowColors) / sizeof(rainbowColors[0])) {
      colorIndex = 0;  // Loop back to the first color
    }
  }
}

// ==================================================
// FLOYD-STEINBERG DITHERING
// ==================================================

// Apply Floyd-Steinberg dithering to RGB565 image buffer
// Optimized: Uses only 2 rows of error buffers (2.8KB vs 345KB) + bit shifts instead of division
void applyFloydSteinbergDithering(uint16_t* buffer, int width, int height) {
  // Two-row error buffer (current + next row only) - 99.2% memory reduction
  // 2 rows × 240 pixels × 3 channels × 2 bytes = 2.8KB (was 345KB)
  int16_t errorBuf[2][DISPLAY_WIDTH * 3];
  memset(errorBuf, 0, sizeof(errorBuf));

  int currRow = 0;
  int nextRow = 1;

  // Process each pixel
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      int idx = y * width + x;
      uint16_t pixel = buffer[idx];

      // Extract RGB565 components to 8-bit
      int16_t oldR = ((pixel >> 11) & 0x1F) << 3;  // 5 bits -> 8 bits
      int16_t oldG = ((pixel >> 5) & 0x3F) << 2;   // 6 bits -> 8 bits
      int16_t oldB = (pixel & 0x1F) << 3;          // 5 bits -> 8 bits

      // Add accumulated error from current row buffer
      oldR = constrain(oldR + errorBuf[currRow][x * 3 + 0], 0, 255);
      oldG = constrain(oldG + errorBuf[currRow][x * 3 + 1], 0, 255);
      oldB = constrain(oldB + errorBuf[currRow][x * 3 + 2], 0, 255);

      // Quantize to RGB565
      int16_t newR = (oldR >> 3) << 3;  // Round to 5 bits
      int16_t newG = (oldG >> 2) << 2;  // Round to 6 bits
      int16_t newB = (oldB >> 3) << 3;  // Round to 5 bits

      // Calculate quantization error
      int16_t errR = oldR - newR;
      int16_t errG = oldG - newG;
      int16_t errB = oldB - newB;

      // Update pixel with quantized value
      buffer[idx] = ((newR >> 3) << 11) | ((newG >> 2) << 5) | (newB >> 3);

      // Distribute error using bit shifts (faster than division)
      // Floyd-Steinberg pattern:
      //        X   7/16
      //  3/16 5/16 1/16

      // Right pixel (7/16) - use bit shift: (err * 7) >> 4 instead of err * 7 / 16
      if (x + 1 < width) {
        errorBuf[currRow][(x + 1) * 3 + 0] += (errR * 7) >> 4;
        errorBuf[currRow][(x + 1) * 3 + 1] += (errG * 7) >> 4;
        errorBuf[currRow][(x + 1) * 3 + 2] += (errB * 7) >> 4;
      }

      // Bottom row pixels (only if not last row)
      if (y + 1 < height) {
        // Bottom-left (3/16)
        if (x > 0) {
          errorBuf[nextRow][(x - 1) * 3 + 0] += (errR * 3) >> 4;
          errorBuf[nextRow][(x - 1) * 3 + 1] += (errG * 3) >> 4;
          errorBuf[nextRow][(x - 1) * 3 + 2] += (errB * 3) >> 4;
        }

        // Bottom (5/16)
        errorBuf[nextRow][x * 3 + 0] += (errR * 5) >> 4;
        errorBuf[nextRow][x * 3 + 1] += (errG * 5) >> 4;
        errorBuf[nextRow][x * 3 + 2] += (errB * 5) >> 4;

        // Bottom-right (1/16)
        if (x + 1 < width) {
          errorBuf[nextRow][(x + 1) * 3 + 0] += errR >> 4;
          errorBuf[nextRow][(x + 1) * 3 + 1] += errG >> 4;
          errorBuf[nextRow][(x + 1) * 3 + 2] += errB >> 4;
        }
      }
    }

    // Swap rows and clear next row for upcoming line
    int temp = currRow;
    currRow = nextRow;
    nextRow = temp;
    memset(errorBuf[nextRow], 0, sizeof(errorBuf[0]));
  }
}

// ==================================================
// TRANSITION FUNCTIONS
// ==================================================

void drawWipeBottomToTop(uint16_t* buffer, int width, int height) {
  for (int16_t row = height - 1; row >= 0; row--) {
    gfx->draw16bitRGBBitmap(0, row, buffer + (row * width), width, 1);
    delayMicroseconds(TRANSITION_WIPE_DELAY_US);  // ~500ms total (240 rows)
  }
}

void drawWipeLeftToRight(uint16_t* buffer, int width, int height) {
  for (int16_t col = 0; col < width; col += 2) {  // 2 pixels at a time
    for (int16_t row = 0; row < height; row++) {
      gfx->drawPixel(col, row, buffer[row * width + col]);
      if (col + 1 < width) {
        gfx->drawPixel(col + 1, row, buffer[row * width + col + 1]);
      }
    }
    delayMicroseconds(TRANSITION_WIPE_DELAY_US);  // ~500ms total (120 iterations)
  }
}

void drawWipeRightToLeft(uint16_t* buffer, int width, int height) {
  for (int16_t col = width - 1; col >= 0; col -= 2) {  // 2 pixels at a time
    for (int16_t row = 0; row < height; row++) {
      gfx->drawPixel(col, row, buffer[row * width + col]);
      if (col - 1 >= 0) {
        gfx->drawPixel(col - 1, row, buffer[row * width + col - 1]);
      }
    }
    delayMicroseconds(TRANSITION_WIPE_DELAY_US);  // ~500ms total (120 iterations)
  }
}

void drawCircularWipe(uint16_t* buffer, int width, int height) {
  int centerX = width / 2;
  int centerY = height / 2;
  int maxRadius = CIRCULAR_WIPE_MAX_RADIUS;  // Diagonal distance

  for (int radius = 0; radius <= maxRadius; radius += 3) {  // Optimized: 2→3px steps
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        int dx = x - centerX;
        int dy = y - centerY;
        int distSq = dx * dx + dy * dy;
        int rSq = radius * radius;
        int rNextSq = (radius + 3) * (radius + 3);  // Match step size

        if (distSq >= rSq && distSq < rNextSq) {
          gfx->drawPixel(x, y, buffer[y * width + x]);
        }
      }
    }
    delayMicroseconds(1000);  // ~500ms total (57 iterations)
  }
}

void drawCheckerboardDissolve(uint16_t* buffer, int width, int height) {
  int blockSize = 8;  // 8x8 blocks

  // 4 passes for checkerboard pattern
  for (int pass = 0; pass < 4; pass++) {
    for (int by = 0; by < height; by += blockSize) {
      for (int bx = 0; bx < width; bx += blockSize) {
        int blockPattern = ((bx / blockSize) + (by / blockSize)) % 4;

        if (blockPattern == pass) {
          // Draw this block
          for (int y = by; y < by + blockSize && y < height; y++) {
            gfx->draw16bitRGBBitmap(bx, y, buffer + (y * width + bx),
                                     min(blockSize, width - bx), 1);
          }
        }
      }
    }
    delay(30);  // ~500ms total (4 passes × 125ms)
  }
}

void drawSlideReveal(uint16_t* buffer, int width, int height) {
  // Slide from left, revealing from right
  for (int offset = width; offset >= 0; offset -= 4) {
    for (int y = 0; y < height; y++) {
      int startX = max(0, offset);
      int drawWidth = width - startX;
      if (drawWidth > 0) {
        gfx->draw16bitRGBBitmap(startX, y, buffer + (y * width + startX),
                                 drawWidth, 1);
      }
    }
    delayMicroseconds(1000);  // ~500ms total (60 iterations)
  }
}

void drawDiagonalWipe(uint16_t* buffer, int width, int height) {
  // Top-left to bottom-right diagonal wipe
  int maxDist = width + height;

  for (int dist = 0; dist < maxDist; dist += 4) {
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        int pixelDist = x + y;
        if (pixelDist >= dist && pixelDist < dist + 4) {
          gfx->drawPixel(x, y, buffer[y * width + x]);
        }
      }
    }
    delayMicroseconds(300);  // ~500ms total (120 iterations)
  }
}

void drawDiagonalWipeInverse(uint16_t* buffer, int width, int height) {
  // Bottom-right to top-left diagonal wipe
  int maxDist = width + height;

  for (int dist = 0; dist < maxDist; dist += 4) {
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        // Calculate distance from bottom-right corner
        int pixelDist = (width - 1 - x) + (height - 1 - y);
        if (pixelDist >= dist && pixelDist < dist + 4) {
          gfx->drawPixel(x, y, buffer[y * width + x]);
        }
      }
    }
    delayMicroseconds(300);  // ~500ms total (120 iterations)
  }
}

void drawVenetianBlindsV(uint16_t* buffer, int width, int height) {
  int stripWidth = 10;  // Width of each blind strip
  int numStrips = (width + stripWidth - 1) / stripWidth;

  // First pass: draw every other strip
  for (int pass = 0; pass < 2; pass++) {
    for (int strip = pass; strip < numStrips; strip += 2) {
      int startX = strip * stripWidth;
      int endX = min(startX + stripWidth, width);
      int drawWidth = endX - startX;

      for (int y = 0; y < height; y++) {
        gfx->draw16bitRGBBitmap(startX, y, buffer + (y * width + startX), drawWidth, 1);
      }
    }
    delay(30);  // Optimized: 50→30ms
  }
}

void drawFourCornerWipe(uint16_t* buffer, int width, int height) {
  int maxDist = (width / 2) + (height / 2);

  for (int dist = 0; dist < maxDist; dist += 3) {  // Optimized: 2→3px steps
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        // Calculate distance from nearest corner
        int d1 = x + y;  // Top-left
        int d2 = (width - 1 - x) + y;  // Top-right
        int d3 = x + (height - 1 - y);  // Bottom-left
        int d4 = (width - 1 - x) + (height - 1 - y);  // Bottom-right

        int minDist = min(min(d1, d2), min(d3, d4));

        if (minDist >= dist && minDist < dist + 3) {  // Match step size
          gfx->drawPixel(x, y, buffer[y * width + x]);
        }
      }
    }
    delayMicroseconds(TRANSITION_WIPE_DELAY_US);  // Optimized: 800→500μs
  }
}

void drawCurtainOpen(uint16_t* buffer, int width, int height) {
  int centerX = width / 2;

  // Wipe from center outward
  for (int offset = 0; offset <= centerX; offset += 3) {  // Optimized: 2→3px steps
    for (int y = 0; y < height; y++) {
      // Left side (wipe left)
      int leftX = centerX - offset;
      if (leftX >= 0 && leftX < width) {
        gfx->draw16bitRGBBitmap(leftX, y, buffer + (y * width + leftX), min(3, centerX - leftX + 1), 1);
      }

      // Right side (wipe right)
      int rightX = centerX + offset;
      if (rightX >= 0 && rightX < width) {
        gfx->draw16bitRGBBitmap(rightX, y, buffer + (y * width + rightX), min(3, width - rightX), 1);
      }
    }
    delayMicroseconds(TRANSITION_WIPE_DELAY_US);  // Optimized: 800→500μs
  }
}

void drawHorizontalSplit(uint16_t* buffer, int width, int height) {
  int centerY = height / 2;

  for (int offset = 0; offset <= centerY; offset += 3) {
    // Top section - wipe upward from center
    int topY = centerY - offset;
    if (topY >= 0) {
      gfx->draw16bitRGBBitmap(0, topY, buffer + (topY * width), width, min(3, centerY - topY + 1));
    }

    // Bottom section - wipe downward from center
    int bottomY = centerY + offset;
    if (bottomY < height) {
      gfx->draw16bitRGBBitmap(0, bottomY, buffer + (bottomY * width), width, min(3, height - bottomY));
    }

    delayMicroseconds(12500);  // ~1 second total animation
  }
}

void drawVerticalSplit(uint16_t* buffer, int width, int height) {
  int centerX = width / 2;

  for (int offset = 0; offset <= centerX; offset += 3) {
    for (int y = 0; y < height; y++) {
      // Left section - wipe leftward from center
      int leftX = centerX - offset;
      if (leftX >= 0) {
        gfx->draw16bitRGBBitmap(leftX, y, buffer + (y * width + leftX), min(3, centerX - leftX + 1), 1);
      }

      // Right section - wipe rightward from center
      int rightX = centerX + offset;
      if (rightX < width) {
        gfx->draw16bitRGBBitmap(rightX, y, buffer + (y * width + rightX), min(3, width - rightX), 1);
      }
    }
    delayMicroseconds(TRANSITION_WIPE_DELAY_US);
  }
}

void drawBarnDoors(uint16_t* buffer, int width, int height) {
  // Barn doors: reveal from top and bottom edges inward, meeting at center
  int halfH = height / 2;
  for (int offset = 0; offset < halfH; offset += 3) {
    for (int row = offset; row < min(offset + 3, halfH); row++) {
      gfx->draw16bitRGBBitmap(0, row, buffer + (row * width), width, 1);
    }
    for (int row = height - 1 - offset; row >= max(height - offset - 3, halfH); row--) {
      gfx->draw16bitRGBBitmap(0, row, buffer + (row * width), width, 1);
    }
    delayMicroseconds(12500);  // ~1 second total animation
  }
}

// Draw one 16x16 block (or smaller at image edge) row-by-row via SPI
static void drawBlockRows(uint16_t* buffer, int bx, int by, int blockSize, int width, int height) {
  for (int row = by; row < by + blockSize && row < height; row++) {
    gfx->draw16bitRGBBitmap(bx, row, buffer + (row * width + bx),
                             min(blockSize, width - bx), 1);
  }
}

void drawRandomBlocks(uint16_t* buffer, int width, int height) {
  const int blockSize = 16;
  const int blocksX = width / blockSize;   // 15
  const int blocksY = height / blockSize;  // 15
  const int totalBlocks = blocksX * blocksY;  // 225

  // Create shuffled array
  int* blockOrder = (int*)malloc(totalBlocks * sizeof(int));
  if (!blockOrder) {
    drawWipeBottomToTop(buffer, width, height);  // Fallback
    return;
  }

  // Initialize and shuffle (Fisher-Yates)
  for (int i = 0; i < totalBlocks; i++) {
    blockOrder[i] = i;
  }
  for (int i = totalBlocks - 1; i > 0; i--) {
    int j = random(0, i + 1);
    int temp = blockOrder[i];
    blockOrder[i] = blockOrder[j];
    blockOrder[j] = temp;
  }

  // Draw blocks (4 per iteration for speed)
  for (int i = 0; i < totalBlocks; i += 4) {
    for (int j = 0; j < 4 && (i + j) < totalBlocks; j++) {
      int blockIdx = blockOrder[i + j];
      int bx = (blockIdx % blocksX) * blockSize;
      int by = (blockIdx / blocksX) * blockSize;

      drawBlockRows(buffer, bx, by, blockSize, width, height);
    }
    delayMicroseconds(800);
  }

  free(blockOrder);
}

void drawZoomBlocks(uint16_t* buffer, int width, int height) {
  // Expand 16x16 blocks outward from center using Chebyshev distance
  const int blockSize = 16;
  const int halfBlock = blockSize / 2;
  int centerX = width / 2;
  int centerY = height / 2;
  int maxDist = max(centerX, centerY) + blockSize;

  for (int dist = 0; dist <= maxDist; dist += blockSize) {
    for (int by = 0; by < height; by += blockSize) {
      for (int bx = 0; bx < width; bx += blockSize) {
        int blockDist = max(abs((bx + halfBlock) - centerX),
                            abs((by + halfBlock) - centerY));
        if (blockDist >= dist && blockDist < dist + blockSize) {
          drawBlockRows(buffer, bx, by, blockSize, width, height);
        }
      }
    }
    delayMicroseconds(20000);
  }
}

void drawZigzagSnake(uint16_t* buffer, int width, int height) {
  for (int i = 0; i < height / 2; i++) {
    // Draw from top
    gfx->draw16bitRGBBitmap(0, i, buffer + (i * width), width, 1);

    // Draw from bottom
    int bottomRow = height - 1 - i;
    gfx->draw16bitRGBBitmap(0, bottomRow, buffer + (bottomRow * width), width, 1);

    delayMicroseconds(TRANSITION_WIPE_DELAY_US);
  }
}

// ==================================================
// LINE-BY-LINE DISPLAY FUNCTION
// ==================================================

void drawImageLineByLine(uint16_t* buffer, int16_t x, int16_t y, int16_t width, int16_t height) {
  Serial.printf("Drawing image line-by-line: %dx%d at (%d,%d)\n", width, height, x, y);

  // Draw the image line by line from top to bottom
  // This creates a visible wipe effect as the new album art appears
  for (int16_t row = 0; row < height; row++) {
    // Draw one horizontal line at a time
    // buffer + (row * width) points to the start of this row's pixel data
    gfx->draw16bitRGBBitmap(x, y + row, buffer + (row * width), width, 1);

    // Small delay to make line-by-line effect visible (~240ms total for 240 lines)
    delayMicroseconds(1000);  // 1ms per line
  }

  Serial.println("Line-by-line drawing complete!");
}

// ==================================================
// RANDOM TRANSITION SELECTOR
// ==================================================

// Helper function to get transition name as string
String getTransitionName(TransitionType transition) {
  switch(transition) {
    case TRANSITION_WIPE_BOTTOM: return "Wipe Up";
    case TRANSITION_WIPE_LEFT: return "Wipe Right";
    case TRANSITION_WIPE_RIGHT: return "Wipe Left";
    case TRANSITION_CIRCULAR: return "Circular";
    case TRANSITION_CHECKERBOARD: return "Checkerboard";
    case TRANSITION_SLIDE_REVEAL: return "Slide";
    case TRANSITION_DIAGONAL: return "Diagonal";
    case TRANSITION_DIAGONAL_INVERSE: return "Diagonal Inverse";
    case TRANSITION_VENETIAN_V: return "Venetian V";
    case TRANSITION_FOUR_CORNER: return "Four Corner";
    case TRANSITION_CURTAIN: return "Curtain";
    case TRANSITION_ZOOM_BLOCKS: return "Zoom Blocks";
    case TRANSITION_HORIZONTAL_SPLIT: return "Horizontal Split";
    case TRANSITION_VERTICAL_SPLIT: return "Vertical Split";
    case TRANSITION_BARN_DOORS: return "Barn Doors";
    case TRANSITION_RANDOM_BLOCKS: return "Random Blocks";
    case TRANSITION_ZIGZAG_SNAKE: return "Zigzag";
    default: return "Unknown";
  }
}

String drawImageWithRandomTransition(uint16_t* buffer, int width, int height) {
  // Pick random transition (avoid repeating the last one)
  TransitionType transition;
  do {
    transition = (TransitionType)random(0, TRANSITION_COUNT);
  } while (transition == lastTransition && TRANSITION_COUNT > 1);

  lastTransition = transition;  // Remember for next time

  String transitionName = getTransitionName(transition);
  Serial.printf("Using transition: %s\n", transitionName.c_str());

  switch(transition) {
    case TRANSITION_WIPE_BOTTOM:
      drawWipeBottomToTop(buffer, width, height);
      break;
    case TRANSITION_WIPE_LEFT:
      drawWipeLeftToRight(buffer, width, height);
      break;
    case TRANSITION_WIPE_RIGHT:
      drawWipeRightToLeft(buffer, width, height);
      break;
    case TRANSITION_CIRCULAR:
      drawCircularWipe(buffer, width, height);
      break;
    case TRANSITION_CHECKERBOARD:
      drawCheckerboardDissolve(buffer, width, height);
      break;
    case TRANSITION_SLIDE_REVEAL:
      drawSlideReveal(buffer, width, height);
      break;
    case TRANSITION_DIAGONAL:
      drawDiagonalWipe(buffer, width, height);
      break;
    case TRANSITION_DIAGONAL_INVERSE:
      drawDiagonalWipeInverse(buffer, width, height);
      break;
    case TRANSITION_VENETIAN_V:
      drawVenetianBlindsV(buffer, width, height);
      break;
    case TRANSITION_FOUR_CORNER:
      drawFourCornerWipe(buffer, width, height);
      break;
    case TRANSITION_CURTAIN:
      drawCurtainOpen(buffer, width, height);
      break;
    case TRANSITION_ZOOM_BLOCKS:
      drawZoomBlocks(buffer, width, height);
      break;
    case TRANSITION_HORIZONTAL_SPLIT:
      drawHorizontalSplit(buffer, width, height);
      break;
    case TRANSITION_VERTICAL_SPLIT:
      drawVerticalSplit(buffer, width, height);
      break;
    case TRANSITION_BARN_DOORS:
      drawBarnDoors(buffer, width, height);
      break;
    case TRANSITION_RANDOM_BLOCKS:
      drawRandomBlocks(buffer, width, height);
      break;
    case TRANSITION_ZIGZAG_SNAKE:
      drawZigzagSnake(buffer, width, height);
      break;
  }

  Serial.println("Transition complete!");
  return transitionName;
}

// ==================================================
// BLUETOOTH CONNECTION SCREEN HELPER
// ==================================================

void showBluetoothConnectionScreen(uint16_t yesColor, uint16_t noColor) {
    gfx->fillScreen(WHITE);

    // Show "Bluetooth connected?" with "Bluetooth" in blue - LARGER & CENTERED
    gfx->setTextSize(3);  // Increased from 2 to 3
    gfx->setTextColor(BLUE);
    gfx->setCursor(39, 70);  // Centered: "Bluetooth" = 9 chars, (240-162)/2 = 39
    gfx->print("Bluetooth");
    gfx->setTextColor(BLACK);
    gfx->println();  // New line
    gfx->setCursor(30, 98);  // Centered: "connected?" = 10 chars, (240-180)/2 = 30
    gfx->print("connected?");

    // Show "yes" and "no" with specified colors - LARGER
    gfx->setTextSize(4);  // Increased from 3 to 4
    gfx->setTextColor(yesColor);
    gfx->setCursor(50, 150);  // Better centered
    gfx->print("yes");

    gfx->setTextColor(noColor);
    gfx->setCursor(150, 150);  // Better centered, even spacing
    gfx->print("no");
}

// ==================================================
// BLUETOOTH LE SETUP FUNCTION
// ==================================================

void setupBLE() {
    Serial.println("\n========================================");
    Serial.println("Bluetooth LE Initialization");
    Serial.println("========================================");

    // Initialize BLE device
    BLEDevice::init("Spotify Display");
    Serial.println("BLE Device initialized: 'Spotify Display'");

    // Create BLE server
    pServer = BLEDevice::createServer();
    pServer->setCallbacks(new MyServerCallbacks());
    Serial.println("BLE Server created");

    // Create BLE service
    BLEService *pService = pServer->createService(SERVICE_UUID);
    Serial.println("BLE Service created");

    // Status characteristic (Read, Notify) - Ready signal
    pStatusChar = pService->createCharacteristic(
        STATUS_CHAR_UUID,
        BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_NOTIFY
    );
    pStatusChar->addDescriptor(new BLE2902());
    Serial.println("  + Status characteristic (ffe1)");

    // Cache check characteristic (Write, Notify) - Cache validation
    pCacheChar = pService->createCharacteristic(
        CACHE_CHAR_UUID,
        BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_NOTIFY
    );
    pCacheChar->setCallbacks(new CacheCheckCallbacks());
    pCacheChar->addDescriptor(new BLE2902());
    Serial.println("  + Cache check characteristic (ffe2)");

    // Image transfer characteristic (Write + Write Without Response, Notify)
    // PROPERTY_WRITE_NO_RESPONSE lets iOS use the fast write path (no per-chunk ACK)
    pImageChar = pService->createCharacteristic(
        IMAGE_CHAR_UUID,
        BLECharacteristic::PROPERTY_WRITE |
        BLECharacteristic::PROPERTY_WRITE_NO_RESPONSE |
        BLECharacteristic::PROPERTY_NOTIFY
    );
    pImageChar->setCallbacks(new ImageTransferCallbacks());
    pImageChar->addDescriptor(new BLE2902());
    Serial.println("  + Image transfer characteristic (ffe3)");

    // Status messages characteristic (Notify) - Error/success messages
    pMsgChar = pService->createCharacteristic(
        MESSAGE_CHAR_UUID,
        BLECharacteristic::PROPERTY_NOTIFY
    );
    pMsgChar->addDescriptor(new BLE2902());
    Serial.println("  + Messages characteristic (ffe4)");

    // Start the service
    pService->start();
    Serial.println("BLE Service started");

    // Start advertising
    BLEAdvertising *pAdvertising = BLEDevice::getAdvertising();
    pAdvertising->addServiceUUID(SERVICE_UUID);
    pAdvertising->setScanResponse(true);
    pAdvertising->setMinPreferred(0x06);  // iPhone connection optimization
    pAdvertising->setMaxPreferred(0x12);

    // Request maximum MTU for faster data transfer (512 byte payload vs 20 byte default)
    BLEDevice::setMTU(517);  // 512 payload + 5 header bytes

    BLEDevice::startAdvertising();

    Serial.println("\n✓ BLE Server ready!");
    Serial.println("✓ Advertising as 'Spotify Display'");
    Serial.println("========================================\n");
}

void setup() {
  // Initialize SD card (REQUIRED for caching)
  pinMode(SD_CS, OUTPUT);

  // CRITICAL: Set RX buffer size BEFORE Serial.begin()
  Serial.setRxBufferSize(16384);  // 16KB buffer for fast reception at 921600 baud
  Serial.begin(921600);
  Serial.setTimeout(3000);  // 3 second timeout (115KB @ 921600 baud ≈ 2.5s + safety margin)
  delay(1000);

  // PSRAM Initialization and check
  Serial.println("\n========================================");
  Serial.println("PSRAM Initialization");
  Serial.println("========================================");
  if (psramFound()) {
    Serial.printf("PSRAM found: %d bytes (%.2f MB)\n", ESP.getPsramSize(), ESP.getPsramSize() / 1024.0 / 1024.0);
    Serial.printf("Free PSRAM: %d bytes (%.2f MB)\n", ESP.getFreePsram(), ESP.getFreePsram() / 1024.0 / 1024.0);
  } else {
    Serial.println("WARNING: PSRAM NOT FOUND!");
    Serial.println("BLE operations may crash due to insufficient memory.");
  }
  Serial.println("========================================\n");

  // FIXED: Initialize backlight BEFORE display (prevents white screen)
  pinMode(TFT_BL, OUTPUT);
  ledcSetup(0, 5000, 8);        // Setup PWM: channel 0, 5kHz, 8-bit
  ledcAttachPin(TFT_BL, 0);
  ledcWrite(0, 50);              // Start at low brightness (20%) during init

  // Hardware reset sequence
  pinMode(TFT_RST, OUTPUT);
  digitalWrite(TFT_RST, HIGH);
  delay(10);
  digitalWrite(TFT_RST, LOW);
  delay(20);
  digitalWrite(TFT_RST, HIGH);
  delay(150);

  // Initialize Arduino_GFX display
  gfx->begin();

  // Configure MADCTL register (0x36) for RGB/BGR color order
  // Using 0x00: RGB mode (matches RGB565 format from Python)
  bus->beginWrite();
  bus->writeCommand(0x36); // MADCTL
  bus->write(0x00);        // Binary: 00000000 - RGB mode
  bus->endWrite();

  // Increase backlight to normal brightness after init complete
  ledcWrite(0, brightness);

  // Initialize SD card for caching
  // Try default SPI first, then FSPI, then HSPI
  bool sdInitialized = false;

  Serial.println("\n========================================");
  Serial.println("ESP32-S3 SD Card Initialization");
  Serial.println("========================================");

  // SD card uses dedicated SPI bus (not shared with display)
  Serial.println("Initializing SD card on dedicated SPI bus:");
  Serial.println("  CLK: 21, MISO: 16, MOSI: 18, CS: 17");

  // Try 1: High speed (25MHz - SD card spec maximum)
  Serial.println("\n1. Testing @ 25MHz...");
  SPI.begin(SD_CLK, SD_MISO, SD_MOSI, SD_CS);
  if (SD.begin(SD_CS, SPI, 25000000)) {
    sdInitialized = true;
    Serial.println("   ✓ SUCCESS @ 25MHz!\n");
    printCardInfo();
  }
  // Try 2: Medium speed for compatibility (if 25MHz fails)
  else {
    Serial.println("   ✗ FAILED @ 25MHz\n");
    Serial.println("2. Testing @ 10MHz (compatibility mode)...");
    SPI.end();
    SPI.begin(SD_CLK, SD_MISO, SD_MOSI, SD_CS);
    if (SD.begin(SD_CS, SPI, 10000000)) {
      sdInitialized = true;
      Serial.println("   ✓ SUCCESS @ 10MHz (card is slower)\n");
      printCardInfo();
    } else {
      Serial.println("   ✗ FAILED @ 10MHz\n");
    }
  }

  if (!sdInitialized) {
    showTroubleshooting();
    Serial.println("FATAL: SD card initialization failed!");
    Serial.println("Caching is REQUIRED for this project");
    Serial.flush();
    gfx->fillScreen(RED);
    gfx->setTextColor(WHITE);
    gfx->setTextSize(1);
    gfx->setCursor(5, 90);
    gfx->println("SD CARD ERROR!");
    gfx->setCursor(5, 110);
    gfx->println("Check:");
    gfx->setCursor(5, 125);
    gfx->println("1.Card inserted?");
    gfx->setCursor(5, 140);
    gfx->println("2.FAT32 format?");
    gfx->setCursor(5, 155);
    gfx->println("3.2-32GB size?");
    while(1) delay(1000); // Halt - SD card required
  }

  // Create cache directory if it doesn't exist
  Serial.println("Creating /cache directory...");
  if (!SD.exists("/cache")) {
    if (SD.mkdir("/cache")) {
      Serial.println("✓ Cache directory created\n");
    } else {
      Serial.println("✗ Failed to create cache directory\n");
    }
  } else {
    Serial.println("✓ Cache directory exists\n");
  }

  Serial.println("========================================");
  Serial.println("SD CARD READY FOR CACHING");
  Serial.println("========================================\n");
  Serial.flush();

  // Show "Hiii" alone first with fade-in effect
  gfx->fillScreen(WHITE);
  gfx->setTextSize(3);
  gfx->setCursor(75, 100);  // Centered vertically

  // Fade in from light gray to black
  for(int fadeVal = 255; fadeVal >= 0; fadeVal -= 15) {
    uint16_t color = RGB565(fadeVal, fadeVal, fadeVal);
    gfx->setTextColor(color, WHITE);  // Text color with background to overwrite previous
    gfx->setCursor(75, 100);
    gfx->print("Hiii");
    delay(50);
  }

  // Display "Hiii" for 2 seconds
  delay(2000);

  // Show "Bluetooth connected?" screen (waiting for script)
  showBluetoothConnectionScreen(BLACK, RED);

  // Brief delay for USB CDC stability (handles Python DTR reset)
  delay(500);

  // Pre-allocate image buffer ONCE from PSRAM to prevent heap fragmentation
  if (psramFound()) {
    imageBuffer = (uint16_t*)ps_malloc(IMAGE_SIZE);  // Allocate from PSRAM
    Serial.println("Allocating image buffer from PSRAM...");
  } else {
    imageBuffer = (uint16_t*)malloc(IMAGE_SIZE);  // Fallback to regular heap
    Serial.println("WARNING: Allocating image buffer from heap (no PSRAM)");
  }

  if (!imageBuffer) {
    Serial.println("FATAL: Cannot allocate image buffer");
    Serial.flush();
    while(1) delay(1000); // Halt system - cannot continue without buffer
  }
  Serial.printf("Image buffer allocated: %d bytes (free heap: %d)\n", IMAGE_SIZE, ESP.getFreeHeap());
  Serial.flush();

  // Initialize Bluetooth LE server
  setupBLE();

  Serial.println("SETUP COMPLETE - BLE MODE ACTIVE.");
  Serial.flush();
}

void flushSerialInput() {
  while (Serial.available()) {
    Serial.read();
  }
}

// Generate 8-character filename from 16-byte cache key
String getCacheFileName(uint8_t* cacheKey) {
  char filename[20];
  sprintf(filename, "/cache/%02X%02X%02X%02X.bin",
          cacheKey[0], cacheKey[1], cacheKey[2], cacheKey[3]);
  return String(filename);
}

// Check if image exists in SD card cache
bool isCached(uint8_t* cacheKey) {
  String filename = getCacheFileName(cacheKey);
  return SD.exists(filename);
}

// Load image from SD card cache
bool loadFromCache(uint8_t* cacheKey) {
  unsigned long startTime = millis();

  String filename = getCacheFileName(cacheKey);
  File file = SD.open(filename, FILE_READ);

  if (!file) {
    Serial.println("ERROR: Cache file not found");
    return false;
  }

  size_t fileSize = file.size();
  if (fileSize != IMAGE_SIZE) {
    Serial.printf("ERROR: Cache size mismatch %d\n", fileSize);
    file.close();
    return false;
  }

  // Read directly into image buffer
  size_t bytesRead = file.read((uint8_t*)imageBuffer, IMAGE_SIZE);
  file.close();

  if (bytesRead != IMAGE_SIZE) {
    Serial.printf("ERROR: Cache read failed %d\n", bytesRead);
    return false;
  }

  unsigned long loadTime = millis() - startTime;
  Serial.printf("Cache HIT: %s (load: %lums)\n", filename.c_str(), loadTime);
  return true;
}

// Save image to SD card cache
bool saveToCache(uint8_t* cacheKey) {
  String filename = getCacheFileName(cacheKey);

  // Delete old file if exists
  if (SD.exists(filename)) {
    SD.remove(filename);
  }

  File file = SD.open(filename, FILE_WRITE);
  if (!file) {
    Serial.println("ERROR: Cannot create cache file");
    return false;
  }

  size_t bytesWritten = file.write((uint8_t*)imageBuffer, IMAGE_SIZE);
  file.close();

  if (bytesWritten != IMAGE_SIZE) {
    Serial.printf("ERROR: Cache write failed %d\n", bytesWritten);
    SD.remove(filename); // Remove incomplete file
    return false;
  }

  Serial.printf("Cache SAVE: %s\n", filename.c_str());
  return true;
}

// Count *.bin files in /cache (for BLE CACHE_COUNT message)
static uint32_t countCacheBinFiles() {
  File root = SD.open("/cache");
  if (!root) {
    return 0;
  }
  if (!root.isDirectory()) {
    root.close();
    return 0;
  }
  uint32_t n = 0;
  for (;;) {
    File f = root.openNextFile();
    if (!f) {
      break;
    }
    if (!f.isDirectory()) {
      String name = String(f.name());
      name.toLowerCase();
      if (name.endsWith(".bin")) {
        n++;
      }
    }
    f.close();
  }
  root.close();
  return n;
}

void loop() {
  // Pulse the red "no" while waiting for connection
  if (showingStartupScreen && !deviceConnected) {
    unsigned long currentMillis = millis();
    if (currentMillis - lastPulseUpdate >= pulseUpdateInterval) {
      lastPulseUpdate = currentMillis;

      // Toggle between red and white
      pulseIsWhite = !pulseIsWhite;
      uint16_t noColor = pulseIsWhite ? WHITE : RED;

      // Clear just the "no" area
      gfx->fillRect(150, 150, 60, 35, WHITE);

      // Redraw "no" with toggling color (red or white)
      gfx->setTextSize(4);
      gfx->setTextColor(noColor);
      gfx->setCursor(150, 150);
      gfx->print("no");
    }
  }

  // BLE stats: number of /cache/*.bin files — sent to the phone app only (never drawn on this display)
  if (statsRequestPending) {
    statsRequestPending = false;
    uint32_t n = countCacheBinFiles();
    String msg = "CACHE_COUNT:" + String((unsigned long)n);
    pMsgChar->setValue(msg.c_str());
    pMsgChar->notify();
    Serial.printf("BLE: %s\n", msg.c_str());
  }

  // Handle cache check (triggered by lightweight callback)
  // This runs in main task with large stack - safe for SD card/display ops
  if (cacheCheckPending) {
    cacheCheckPending = false;

    Serial.println("Processing cache check request...");

    // Check if image is cached
    cacheHit = isCached(currentCacheKey);

    if (cacheHit) {
      unsigned long totalStartTime = millis();
      Serial.println("BLE: Cache HIT");

      // Load and display cached image
      if (loadFromCache(currentCacheKey)) {
        // Hide startup screen when displaying image
        showingStartupScreen = false;

        // NOTE: No dithering needed - cache already contains dithered image!
        // Dithering happens before saving (see line ~864), so cached image is pre-dithered

        // Draw image with random transition
        unsigned long displayStart = millis();
        String transitionName = drawImageWithRandomTransition(imageBuffer, DISPLAY_WIDTH, DISPLAY_HEIGHT);
        unsigned long displayTime = millis() - displayStart;

        unsigned long totalTime = millis() - totalStartTime;
        Serial.printf("⚡ Cache hit total: %lums (display: %lums)\n", totalTime, displayTime);

        // Send transition name FIRST (before cache response)
        // This ensures Python receives it before printing the cache hit message
        String transitionMsg = "TRANSITION:" + transitionName;
        pMsgChar->setValue(transitionMsg.c_str());
        pMsgChar->notify();
        delay(10);  // Small delay to ensure message is sent before cache response

        // Notify CACHED response AFTER drawing completes
        // This prevents Python from sending new data while we're still drawing
        uint8_t response = 0x01;
        pCacheChar->setValue(&response, 1);
        pCacheChar->notify();

        // Send SUCCESS message
        pMsgChar->setValue("SUCCESS");
        pMsgChar->notify();
      } else {
        Serial.println("ERROR: Cache load failed");
        pMsgChar->setValue("ERROR: Cache load failed");
        pMsgChar->notify();
      }
    } else {
      Serial.println("BLE: Cache MISS");

      // Notify: NEED (0x00)
      uint8_t response = 0x00;
      pCacheChar->setValue(&response, 1);
      pCacheChar->notify();
    }
  }

  // Progressive drawing: draw new lines as data arrives
  if (imageState == RECEIVING_DATA && receivedBytes > lastDrawnBytes) {
    // Calculate how many complete lines we have
    uint32_t bytesPerLine = DISPLAY_WIDTH * 2;  // 240 pixels * 2 bytes per pixel = 480 bytes
    uint32_t completedLines = receivedBytes / bytesPerLine;
    uint32_t drawnLines = lastDrawnBytes / bytesPerLine;

    // Draw any new complete lines
    if (completedLines > drawnLines) {
      // Hide startup screen on first draw
      if (showingStartupScreen) {
        showingStartupScreen = false;
      }

      // Draw the new lines (without dithering for speed)
      for (uint32_t line = drawnLines; line < completedLines; line++) {
        gfx->draw16bitRGBBitmap(0, line, imageBuffer + (line * DISPLAY_WIDTH), DISPLAY_WIDTH, 1);
      }

      lastDrawnBytes = completedLines * bytesPerLine;
    }
  }

  // Handle image transfer complete (triggered by lightweight callback)
  // This runs in main task with large stack - safe for SD card/display ops
  if (imageTransferComplete) {
    imageTransferComplete = false;
    lastDrawnBytes = 0;  // Reset for next transfer

    Serial.println("Processing image transfer completion...");

    // Notify SUCCESS IMMEDIATELY to prevent Python timeout
    uint8_t success = 0x01;
    pImageChar->setValue(&success, 1);
    pImageChar->notify();

    pMsgChar->setValue("SUCCESS");
    pMsgChar->notify();

    Serial.println("Transfer acknowledged, now processing...");

    // Apply Floyd-Steinberg dithering for better image quality
    unsigned long ditherStart = millis();
    Serial.println("Applying dithering...");
    applyFloydSteinbergDithering(imageBuffer, DISPLAY_WIDTH, DISPLAY_HEIGHT);
    unsigned long ditherTime = millis() - ditherStart;

    // Redraw the full image with dithering applied
    unsigned long displayStart = millis();
    Serial.println("Redrawing with dithering...");
    drawImageLineByLine(imageBuffer, 0, 0, DISPLAY_WIDTH, DISPLAY_HEIGHT);
    unsigned long displayTime = millis() - displayStart;

    // Save to cache
    unsigned long saveStart = millis();
    saveToCache(currentCacheKey);
    unsigned long saveTime = millis() - saveStart;

    Serial.printf("⚡ Processing: dither %lums, display %lums, save %lums\n",
                   ditherTime, displayTime, saveTime);
    Serial.println("Image processing complete!");
  }

  // Handle BLE connection state changes
  if (!deviceConnected && oldDeviceConnected) {
    // Client just disconnected
    pServer->startAdvertising();  // Restart advertising
    Serial.println("BLE: Restarted advertising after disconnect");
    oldDeviceConnected = deviceConnected;
  }

  if (deviceConnected && !oldDeviceConnected) {
    // Client just connected
    Serial.println("BLE: Client connected, ready for data");
    oldDeviceConnected = deviceConnected;
  }

  // Small delay to prevent tight loop
  delay(10);
}

// SD Card diagnostic functions
void printCardInfo() {
  Serial.println("========================================");
  Serial.println("SD CARD INFORMATION");
  Serial.println("========================================");

  uint8_t cardType = SD.cardType();
  Serial.print("Card Type: ");
  switch(cardType) {
    case CARD_NONE:
      Serial.println("NONE (No card detected)");
      return;
    case CARD_MMC:
      Serial.println("MMC");
      break;
    case CARD_SD:
      Serial.println("SDSC (Standard Capacity)");
      break;
    case CARD_SDHC:
      Serial.println("SDHC (High Capacity)");
      break;
    default:
      Serial.println("UNKNOWN");
  }

  uint64_t cardSize = SD.cardSize() / (1024 * 1024);
  Serial.printf("Card Size: %llu MB\n", cardSize);

  uint64_t totalBytes = SD.totalBytes() / (1024 * 1024);
  Serial.printf("Total Space: %llu MB\n", totalBytes);

  uint64_t usedBytes = SD.usedBytes() / (1024 * 1024);
  Serial.printf("Used Space: %llu MB\n", usedBytes);

  uint64_t freeBytes = (SD.totalBytes() - SD.usedBytes()) / (1024 * 1024);
  Serial.printf("Free Space: %llu MB\n\n", freeBytes);
}

void testFileOperations() {
  Serial.println("========================================");
  Serial.println("FILE OPERATIONS TEST");
  Serial.println("========================================");

  // Test 1: Create directory
  Serial.println("1. Creating /test directory...");
  if (SD.mkdir("/test")) {
    Serial.println("   ✓ Directory created\n");
  } else {
    if (SD.exists("/test")) {
      Serial.println("   ✓ Directory already exists\n");
    } else {
      Serial.println("   ✗ FAILED to create directory\n");
      return;
    }
  }

  // Test 2: Write file
  Serial.println("2. Writing test file...");
  File file = SD.open("/test/hello.txt", FILE_WRITE);
  if (file) {
    file.println("Hello from ESP32-S3!");
    file.println("SD card is working!");
    file.close();
    Serial.println("   ✓ File written\n");
  } else {
    Serial.println("   ✗ FAILED to open file for writing\n");
    return;
  }

  // Test 3: Read file
  Serial.println("3. Reading test file...");
  file = SD.open("/test/hello.txt", FILE_READ);
  if (file) {
    Serial.println("   File contents:");
    while (file.available()) {
      Serial.write(file.read());
    }
    file.close();
    Serial.println("   ✓ File read successfully\n");
  } else {
    Serial.println("   ✗ FAILED to open file for reading\n");
    return;
  }

  Serial.println("========================================");
  Serial.println("FILE OPERATIONS: ALL TESTS PASSED!");
  Serial.println("========================================\n");
}

void showTroubleshooting() {
  Serial.println("========================================");
  Serial.println("TROUBLESHOOTING");
  Serial.println("========================================");
  Serial.println("SD card initialization failed!");
  Serial.println("\nPossible issues:");
  Serial.println("1. No SD card inserted");
  Serial.println("2. Card not formatted as FAT32");
  Serial.println("3. Card >32GB (needs special formatting)");
  Serial.println("4. Fake/damaged SD card");
  Serial.println("5. Poor contact in SD card slot");
  Serial.println("6. Incompatible SD card type");
  Serial.println("\nRecommendations:");
  Serial.println("- Try a different SD card");
  Serial.println("- Use 2-32GB card");
  Serial.println("- Format as FAT32");
  Serial.println("- Check card is fully inserted");
  Serial.println("- Try cleaning card contacts");
  Serial.println("========================================\n");
}
