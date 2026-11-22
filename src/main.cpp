// ESP32 Album Art Display - Arduino_GFX Version
// Receives and displays RGB565 images from Python via Bluetooth LE
// Repo: spotify-display1 — BLE GATT contract: docs/BLE_PROTOCOL.md (keep in sync with Python + iOS)

#include <Arduino_GFX_Library.h>
#include <SD.h>
#include <FS.h>
#include <SPI.h>
#include <ctype.h>
#include <stdlib.h>

// Bluetooth LE includes
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>
#include <esp_gap_ble_api.h>
// Inflate (raw DEFLATE) lives in the S3 ROM: no library, no flash cost. BLE_PROTOCOL 1.11.
#include "esp32s3/rom/miniz.h"

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

// On-board WS2812B RGB LED (Waveshare schematic: GPIO15). Status light — see ledPoll().
#define STATUS_LED_PIN 15

#define DISPLAY_WIDTH 240
#define DISPLAY_HEIGHT 240
#define IMAGE_SIZE (DISPLAY_WIDTH * DISPLAY_HEIGHT * 2)
#define CACHE_KEY_VERSION 1
#define CACHE_INDEX_MAX_ENTRIES 1024

// Performance and timing constants
// Backlight level at power-up, before the app sends its saved slider value (out of 255).
// 180 = owner's preferred level (2026-11-22), ~70% of the panel's rated backlight current.
#define TFT_BRIGHTNESS_MAX 180
// LEDC PWM channel driving the backlight. NOT a GPIO: on Arduino-ESP32 core 2.x
// ledcWrite()/ledcSetup() take a CHANNEL (0-7 on the S3), while ledcAttachPin()
// binds that channel to the TFT_BL pin. Passing the pin number to ledcWrite()
// silently targets a nonexistent channel and the backlight never changes.
#define TFT_BL_PWM_CHANNEL 0
#define TRANSITION_WIPE_DELAY_US 500
#define CIRCULAR_WIPE_MAX_RADIUS 170

// Create display bus and display objects with higher SPI frequency
// 40 MHz: the ST7789's rated write clock is ~62.5 MHz, and 80 MHz garbled transfers (webcam +
// serial recordings 2026-11-20: covers logged as drawn never appeared, or left one line / stray
// squares). The ESP32-S3 SPI clock is 80 MHz / integer, so 40 is the fastest setting below 80.
Arduino_DataBus *bus = new Arduino_ESP32SPI(TFT_DC, TFT_CS, TFT_SCLK, TFT_MOSI, 1 /* MISO */, FSPI /* spi_num */, 40000000 /* freq 40MHz */);
// ST7789VW chip - using IPS=true (enable color inversion for correct colors)
Arduino_GFX *gfx = new Arduino_ST7789(bus, TFT_RST, 0 /* rotation */, true /* IPS */, 240, 240, 0, 0);

// Brightness control - maximum for vibrant display
// ST7789VW spec: 250 cd/m² typical luminance, 800:1 contrast ratio
int brightness = TFT_BRIGHTNESS_MAX;  // 100% brightness for maximum vibrancy

// Pre-allocated image buffers (prevents heap fragmentation), both in PSRAM.
// imageBuffer = the picture on the panel: what SD load/save and transitions use.
// rxBuffer    = where BLE chunks land. Nothing is drawn from it while it fills: a new song
//               appears only once complete (copied to imageBuffer, drawn with a transition).
//               A transfer abandoned by a skip therefore never touches the screen.
static uint16_t* imageBuffer = nullptr;
static uint16_t* rxBuffer = nullptr;
// Compressed transfers (BLE_PROTOCOL 1.11): the deflated bytes land here, loop() inflates them
// into rxBuffer once the frame is whole. The decompressor state is ~11 KB, so it lives in PSRAM,
// never on a stack (loop()'s is 8 KB; BTC_TASK's far smaller).
static uint8_t* rxPacked = nullptr;
static tinfl_decompressor* inflator = nullptr;
// prevBuffer    = copy of the picture last drawn by a transition (the old cover), so frame-based
//                 transitions can mix old and new. imageBuffer can't serve: a cache hit loads
//                 the new cover straight into it.
// composeBuffer = scratch frame those transitions build before pushing it to the panel.
static uint16_t* prevBuffer = nullptr;
static uint16_t* composeBuffer = nullptr;
// False whenever a non-cover screen (startup / ready / Bluetooth) is up: the old frame is then
// treated as black instead of a stale cover.
static bool panelShowsImage = false;

// ==================================================
// BLUETOOTH LE CONFIGURATION
// ==================================================

// BLE Service and Characteristic UUIDs
#define SERVICE_UUID        "0000ffe0-0000-1000-8000-00805f9b34fb"
#define STATUS_CHAR_UUID    "0000ffe1-0000-1000-8000-00805f9b34fb"
#define CACHE_CHAR_UUID     "0000ffe2-0000-1000-8000-00805f9b34fb"
#define IMAGE_CHAR_UUID     "0000ffe3-0000-1000-8000-00805f9b34fb"
#define MESSAGE_CHAR_UUID   "0000ffe4-0000-1000-8000-00805f9b34fb"
#define BRIGHTNESS_CHAR_UUID "0000ffe5-0000-1000-8000-00805f9b34fb"
#define STATUS_LED_CHAR_UUID "0000ffe6-0000-1000-8000-00805f9b34fb"

// BLE Server and Characteristics
BLEServer* pServer = nullptr;
BLECharacteristic* pStatusChar = nullptr;
BLECharacteristic* pCacheChar = nullptr;
BLECharacteristic* pImageChar = nullptr;
BLECharacteristic* pMsgChar = nullptr;
BLECharacteristic* pBrightnessChar = nullptr;

// Set from BLE callbacks (flag only); loop() turns it into the red status-LED blink.
volatile bool ledErrorPending = false;

/// NOTIFY: Message `ERROR:*` plus Image byte 0x02 so the phone can fail the SUCCESS wait without a 32s timeout.
static void notifyImageTransferRejected(const char* utf8message) {
  ledErrorPending = true;
  if (pMsgChar) {
    pMsgChar->setValue(utf8message);
    pMsgChar->notify();
  }
  if (pImageChar) {
    uint8_t b = 0x02;
    pImageChar->setValue(&b, 1);
    pImageChar->notify();
  }
}

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
// Frame being received is deflate-compressed (10-byte header). Chunks go to rxPacked.
bool rxCompressed = false;
// Snapshot of rxCompressed when the frame completed (callback resets state right after).
volatile bool completedCompressed = false;
#define IMAGE_FORMAT_DEFLATE 0x01
uint8_t currentCacheKey[16];
// Key of the frame being received, snapshotted when its header arrives. A later cache check
// overwrites currentCacheKey, so saving with currentCacheKey could file this frame's pixels
// under the next song's key (a cache entry with a valid CRC but the wrong picture).
uint8_t transferCacheKey[16];
bool cacheHit = false;
uint8_t pendingTransition = 0xFF;  // 0xFF means random transition

// Prefetch (BLE_PROTOCOL 1.8). The app sends the NEXT queued song's cover ahead of time:
// - CACHE_PROBE_MAGIC on the Cache characteristic: "is this key on SD?" — answers 0x01/0x00 like a
//   normal check but never loads or draws (a normal check draws on a hit).
// - Image header transition byte TRANSITION_STORE_ONLY: receive and save to SD, never draw.
#define CACHE_PROBE_MAGIC 0xDEADBEE0u
#define TRANSITION_STORE_ONLY 0xFE
volatile bool cacheProbeOnly = false;  // the pending cache check is a probe

// BLE_PROTOCOL 1.12.
// - TRANSITION_MASK_MAGIC on the Cache characteristic: 4-byte magic + 8-byte LE bitmask (bit i = header
//   transition index i may be picked at random) + 8 padding bytes. Sent by the app on every connect.
//   Not persisted: after a power cycle every transition is allowed until the app says otherwise.
// - Image header transition byte TRANSITION_DISPLAY_ONLY: draw the frame (random enabled transition)
//   but do NOT save it to SD. Used for photo uploads.
#define TRANSITION_MASK_MAGIC 0xCAC4E1EBu
#define TRANSITION_DISPLAY_ONLY 0xFD
// Two 32-bit halves (written from the BLE callback, read in loop()); a torn update only ever mixes two
// complete masks, which is harmless.
static volatile uint32_t transitionMaskLo = 0xFFFFFFFFu;
static volatile uint32_t transitionMaskHi = 0xFFFFFFFFu;

#include "transitions_core.h"  // TransitionType, shared with the iOS app

// Track last transition to avoid repeats
static TransitionType lastTransition = TRANSITION_COUNT;  // Invalid value initially

// Cache health/metrics counters
uint32_t cacheEntryCount = 0;
uint32_t cacheCRCErrors = 0;
uint32_t cacheRecoveries = 0;

struct CacheIndexEntry {
  uint8_t key[16];
  bool used;
};
static CacheIndexEntry cacheIndex[CACHE_INDEX_MAX_ENTRIES];

// Forward declarations
void flushSerialInput();
void printCardInfo();
void testFileOperations();
void showTroubleshooting();
bool isCached(uint8_t* cacheKey);
bool loadFromCache(uint8_t* cacheKey);
bool saveToCache(uint8_t* cacheKey, const uint16_t* src = nullptr);  // src defaults to imageBuffer
String getCacheFileNameVersioned(const uint8_t* cacheKey, uint8_t version);
bool parseCacheFilenameToKey(const String& path, uint8_t* outKey, uint8_t* outVersion);
void buildCacheIndex();
bool cacheIndexContains(const uint8_t* cacheKey);
bool cacheIndexInsert(const uint8_t* cacheKey);
bool cacheIndexRemove(const uint8_t* cacheKey);
void clearCacheIndex();
bool removeCacheFileAndIndex(const String& filename, const uint8_t* cacheKey);
void publishCacheCount();
void publishCacheStats();
void enforceCacheCapacityHook();
uint32_t computeCRC32(const uint8_t* data, size_t len);
void clearCacheDirectory();
void printRainbowText(String text, int x, int y, int textSize);
void showBluetoothConnectionScreen(uint16_t yesColor, uint16_t noColor);
void resetToWaitingScreen();

// BLE work flags (set by callbacks, processed in loop())
// CRITICAL: Callbacks must be lightweight to prevent BTC_TASK stack overflow
volatile bool cacheCheckPending = false;
volatile bool statsRequestPending = false;
volatile bool clearCachePending = false;
volatile bool imageTransferComplete = false;
volatile uint32_t completedImageBytes = 0;  // Snapshot bytes received at completion

// Rainbow text animation state
int currentRainbowIndex = 0;
unsigned long lastRainbowUpdate = 0;
const unsigned long rainbowUpdateInterval = 200; // Update every 150ms (smooth wave speed)
bool showingStartupScreen = true;

// Pulsing "no" animation state
unsigned long lastPulseUpdate = 0;

// Background wake-up for the iOS app (BLE_PROTOCOL 1.7). iOS suspends the app ~30 s after it
// leaves the foreground, but a notify on a subscribed characteristic wakes it briefly. Each "HB"
// lets the app poll Spotify once, so the display keeps up while the phone is locked.
#define HEARTBEAT_INTERVAL_MS 1000
unsigned long lastHeartbeatMs = 0;
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

// LE PHY negotiation result (BLE 5). Set on BTC_TASK, logged by loop().
volatile bool phyUpdatePending = false;
volatile uint8_t phyTx = 0, phyRx = 0, phyStatus = 0;

// Data length extension result (LE packet payload: 27 bytes default, 251 max).
volatile bool dleUpdatePending = false;
volatile uint16_t dleTx = 0, dleRx = 0;
volatile uint8_t dleStatus = 0;

// Connection interval. onConnect asks for 7.5–15 ms; iOS may refuse anything under 15 ms (Apple's
// accessory guidelines), and a refused request leaves the link at iOS's ~30 ms default. So loop()
// watches the outcome and, once per connection, falls back to the 15 ms request iOS accepts.
// Units: 1.25 ms (interval), 10 ms (supervision timeout).
#define CONN_INT_FAST_MIN 6           // 7.5 ms
#define CONN_INT_FAST_MAX 12          // 15 ms
#define CONN_INT_SAFE 12              // 15 ms min = max: the shortest Apple-compliant request
#define CONN_SUPERVISION_TIMEOUT 400  // 4 s
volatile bool connParamsPending = false;
volatile uint8_t connParamsStatus = 0;
volatile uint16_t connIntervalUnits = 0;
esp_bd_addr_t peerAddr = {0};
volatile bool peerAddrValid = false;
bool connIntervalFallbackSent = false;  // loop() only; reset on each new connection

static void onGapEvent(esp_gap_ble_cb_event_t event, esp_ble_gap_cb_param_t* param) {
    if (event == ESP_GAP_BLE_PHY_UPDATE_COMPLETE_EVT) {
        phyStatus = param->phy_update.status;
        phyTx = param->phy_update.tx_phy;
        phyRx = param->phy_update.rx_phy;
        phyUpdatePending = true;
    } else if (event == ESP_GAP_BLE_SET_PKT_LENGTH_COMPLETE_EVT) {
        dleStatus = param->pkt_data_lenth_cmpl.status;
        dleTx = param->pkt_data_lenth_cmpl.params.tx_len;
        dleRx = param->pkt_data_lenth_cmpl.params.rx_len;
        dleUpdatePending = true;
    } else if (event == ESP_GAP_BLE_UPDATE_CONN_PARAMS_EVT) {
        connParamsStatus = param->update_conn_params.status;
        connIntervalUnits = param->update_conn_params.conn_int;
        connParamsPending = true;
    }
}

// Server callbacks - handle connection/disconnection events
class MyServerCallbacks: public BLEServerCallbacks {
    void onConnect(BLEServer* pServer) {
        deviceConnected = true;
        Serial.println("BLE Client connected");

        // Keep the status value readable as 0x01. Notifications sent here are dropped because
        // the phone has not subscribed yet (it is still discovering services), so iOS reads
        // this value after subscribing instead of relying on the notify below.
        uint8_t ready = 0x01;
        pStatusChar->setValue(&ready, 1);
        pStatusChar->notify();

        // Send READY message (best-effort; reaches clients that subscribe quickly)
        pMsgChar->setValue("READY");
        pMsgChar->notify();
        Serial.println("BLE: Sent READY signal");
        // Display drawing is deferred to loop() — BTC_TASK stack is tiny.
    }

    // Ask the phone for a 7.5–15 ms connection interval (iOS default is ~30 ms). Image transfer
    // throughput scales with connection events: ~28 KB/s at 30 ms → one 115 KB cover took ~3.7 s.
    // If iOS refuses, loop() falls back to 15 ms (CONN_INT_SAFE).
    // Also ask for the largest LE packet (data length extension: 251-byte payloads instead of 27),
    // so each 512-byte write needs 3 radio packets instead of 19.
    // Lightweight (each call only queues a GAP request) — safe on the small BTC_TASK stack.
    void onConnect(BLEServer* pServer, esp_ble_gatts_cb_param_t* param) {
        memcpy(peerAddr, param->connect.remote_bda, sizeof(esp_bd_addr_t));
        peerAddrValid = true;
        pServer->updateConnParams(param->connect.remote_bda, CONN_INT_FAST_MIN, CONN_INT_FAST_MAX, 0,
                                  CONN_SUPERVISION_TIMEOUT);
        Serial.println("BLE: Requested 7.5-15 ms connection interval");
        esp_ble_gap_set_pkt_data_len(param->connect.remote_bda, 251);
        Serial.println("BLE: Requested 251-byte data length");
        // Ask for the LE 2M PHY (BLE 5; ESP32-S3 and iPhone 8+ support it): twice the radio bit
        // rate, so the ~2.2 s 115 KB cover transfer should shrink. The phone may decline; the
        // outcome is logged from loop() as "BLE: PHY tx=… rx=…". Also only queues a GAP request.
        esp_ble_gap_set_prefered_phy(param->connect.remote_bda, 0,
                                     ESP_BLE_GAP_PHY_2M_PREF_MASK, ESP_BLE_GAP_PHY_2M_PREF_MASK,
                                     ESP_BLE_GAP_PHY_OPTIONS_NO_PREF);
    }

    void onDisconnect(BLEServer* pServer) {
        deviceConnected = false;
        peerAddrValid = false;
        uint8_t notReady = 0x00;
        pStatusChar->setValue(&notReady, 1);
        Serial.println("BLE Client disconnected");
        // Defer UI reset + advertising restart to loop() single-owner disconnect path.
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

        // Enabled-transitions mask (iOS app, 1.12): magic + u64 LE bitmask + 8 bytes padding.
        // Only stores two words; nothing else to do, so it is safe on this task.
        if (magic == TRANSITION_MASK_MAGIC) {
            auto word = [&](size_t off) {
                return (uint32_t)(uint8_t)value[off] | ((uint32_t)(uint8_t)value[off + 1] << 8) |
                       ((uint32_t)(uint8_t)value[off + 2] << 16) | ((uint32_t)(uint8_t)value[off + 3] << 24);
            };
            transitionMaskLo = word(4);
            transitionMaskHi = word(8);
            return;
        }

        // Clear-cache command (iOS app): magic + 16 bytes padding
        if (magic == 0xCAC4E1EA) {
            clearCachePending = true;
            return;
        }

        if (magic != 0xDEADBEEF && magic != CACHE_PROBE_MAGIC) {
            Serial.printf("ERROR: Bad magic 0x%08X\n", magic);
            return;
        }

        // Extract and store cache key (next 16 bytes). A store-only transfer that follows a probe
        // snapshots this key at its header, exactly like a normal miss → transfer.
        memcpy(currentCacheKey, value.data() + 4, 16);
        cacheProbeOnly = (magic == CACHE_PROBE_MAGIC);

        // Set flag for loop() to process
        // CRITICAL: Don't do SD card/display work here - BTC_TASK stack is tiny!
        cacheCheckPending = true;

        // Return immediately - let loop() do the heavy work
    }
};

// A frame header written to the Image characteristic (BLE_PROTOCOL 1.11):
//   4 bytes  size u32 LE                                   (legacy, random transition)
//   5 bytes  transition + size u32 LE
//  10 bytes  transition + format (0x01 = raw DEFLATE) + raw size u32 LE + packed size u32 LE
// Every form describes one 115,200-byte RGB565 frame. Only the 10-byte form is compressed.
struct ImageHeader {
    uint8_t transition;
    bool compressed;
    uint32_t payloadBytes;  // bytes that follow on the wire (packed size when compressed)
};

inline uint32_t decodeLE32At(const std::string& v, size_t off) {
    return (uint8_t)v[off] | ((uint8_t)v[off + 1] << 8) | ((uint8_t)v[off + 2] << 16) | ((uint8_t)v[off + 3] << 24);
}

inline bool isImageHeaderLength(size_t n) { return n == 4 || n == 5 || n == 10; }

// True only for a well-formed header of a 240x240 frame. No allocation: safe on BTC_TASK.
static bool parseImageHeader(const std::string& v, ImageHeader& h) {
    if (v.length() == 4) {
        h = { 0xFF, false, decodeLE32At(v, 0) };
        return h.payloadBytes == IMAGE_SIZE;
    }
    if (v.length() == 5) {
        h = { (uint8_t)v[0], false, decodeLE32At(v, 1) };
        return h.payloadBytes == IMAGE_SIZE;
    }
    if (v.length() == 10) {
        if ((uint8_t)v[1] != IMAGE_FORMAT_DEFLATE || !rxPacked || !inflator) return false;
        uint32_t rawSize = decodeLE32At(v, 2);
        uint32_t packed = decodeLE32At(v, 6);
        if (rawSize != IMAGE_SIZE || packed == 0 || packed > IMAGE_SIZE) return false;
        h = { (uint8_t)v[0], true, packed };
        return true;
    }
    return false;
}

// Inflates one raw-DEFLATE frame (BLE_PROTOCOL 1.11) into `out` (IMAGE_SIZE bytes). loop() only:
// takes ~10-30 ms. True only if the stream ends cleanly with exactly IMAGE_SIZE bytes.
static bool inflateFrame(const uint8_t* in, size_t inBytes, uint8_t* out, size_t* outBytes) {
    *outBytes = 0;
    if (!in || !out || !inflator || inBytes == 0) return false;
    tinfl_init(inflator);
    size_t inSize = inBytes;
    size_t outSize = IMAGE_SIZE;
    // Whole input present (no HAS_MORE_INPUT); output buffer holds the whole frame.
    tinfl_status st = tinfl_decompress(inflator, in, &inSize, out, out, &outSize,
                                       TINFL_FLAG_USING_NON_WRAPPING_OUTPUT_BUF);
    *outBytes = outSize;
    return st == TINFL_STATUS_DONE && outSize == IMAGE_SIZE;
}

// Image transfer callbacks - handle image data reception
// LIGHTWEIGHT: Only receives data and sets flag, heavy work done in loop()
class ImageTransferCallbacks: public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pCharacteristic) {
        std::string value = pCharacteristic->getValue();
        ImageHeader hdr;

        if (imageState == WAITING_FOR_SIZE) {
            if (!isImageHeaderLength(value.length())) {
                Serial.printf("ERROR: Expected 4/5/10-byte header, got %d\n", value.length());
                notifyImageTransferRejected("ERROR: Invalid image header");
                return;
            }
            if (!parseImageHeader(value, hdr)) {
                Serial.printf("ERROR: Bad %d-byte image header\n", value.length());
                notifyImageTransferRejected(value.length() == 10 ? "ERROR: Invalid image header"
                                                                 : "ERROR: Size mismatch");
                imageState = WAITING_FOR_SIZE;  // Reset
                return;
            }

            pendingTransition = hdr.transition;
            expectedSize = hdr.payloadBytes;
            rxCompressed = hdr.compressed;
            Serial.printf("BLE: Expecting %u bytes%s\n", (unsigned)expectedSize, rxCompressed ? " (deflate)" : "");
            memcpy(transferCacheKey, currentCacheKey, sizeof(transferCacheKey));
            receivedBytes = 0;
            imageState = RECEIVING_DATA;

        } else if (imageState == RECEIVING_DATA) {
            // New image header mid-stream: client cancelled and started a fresh transfer
            if (isImageHeaderLength(value.length()) && parseImageHeader(value, hdr)) {
                Serial.println("BLE: Image header (resync) — discarding partial frame");
                pendingTransition = hdr.transition;
                expectedSize = hdr.payloadBytes;
                rxCompressed = hdr.compressed;
                memcpy(transferCacheKey, currentCacheKey, sizeof(transferCacheKey));
                receivedBytes = 0;
                // Prevent a stale completion from a prior partial frame from firing in loop().
                imageTransferComplete = false;
                completedImageBytes = 0;
                return;
            }

            // Subsequent writes are image data chunks
            size_t chunkSize = value.length();

            if (receivedBytes + chunkSize > expectedSize) {
                Serial.println("ERROR: Buffer overflow");
                notifyImageTransferRejected("ERROR: Buffer overflow");
                imageState = WAITING_FOR_SIZE;  // Reset
                receivedBytes = 0;
                return;
            }

            // Copy chunk to the receive buffer (memcpy is fast, safe in callback). Never imageBuffer:
            // that holds the last complete picture, which loop() may be reading for a transition.
            uint8_t* dst = rxCompressed ? rxPacked : (uint8_t*)rxBuffer;
            memcpy(dst + receivedBytes, value.data(), chunkSize);
            receivedBytes += chunkSize;

            // Log progress (every 10KB or final)
            if (receivedBytes % 10240 == 0 || receivedBytes == expectedSize) {
                uint8_t progress = (receivedBytes * 100) / expectedSize;
                Serial.printf("BLE Progress: %d%%\n", progress);
            }

            // Check if complete
            if (receivedBytes == expectedSize) {
                Serial.println("BLE: Image transfer complete");
                completedImageBytes = receivedBytes;
                completedCompressed = rxCompressed;

                // Set flag for loop() to handle inflate/display/save
                // CRITICAL: Don't do display/SD card work here - BTC_TASK stack is tiny!
                imageTransferComplete = true;

                // Reset state immediately to prevent buffer overflow from late chunks
                imageState = WAITING_FOR_SIZE;
                receivedBytes = 0;
                expectedSize = 0;
                rxCompressed = false;

                // Return immediately - let loop() do the heavy work
            }
        }
    }
};

// Status LED brightness from the app (BLE_PROTOCOL 1.13, ffe6): 0..255 of the STATUS_LED_MAX cap,
// so the app can never push the LED past ~47%. 255 = the full cap (default), 0 = LED always off.
// Callback only stores the byte; loop() picks it up on the next LED update.
volatile uint8_t statusLedLevel = 255;

class StatusLedCallbacks: public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pCharacteristic) {
        std::string value = pCharacteristic->getValue();
        if (value.length() != 1) return;
        statusLedLevel = (uint8_t)value[0];
    }
};

class BrightnessCallbacks: public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pCharacteristic) {
        std::string value = pCharacteristic->getValue();
        if (value.length() != 1) {
            Serial.printf("ERROR: Brightness write got %d bytes, expected 1\n", value.length());
            return;
        }
        brightness = (uint8_t)value[0];
        ledcWrite(TFT_BL_PWM_CHANNEL, brightness);
        Serial.printf("BLE: Brightness set to %d\n", brightness);
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
// TRANSITION FUNCTIONS: the transitions themselves live in the shared core
// (SpotifyDisplay.swiftpm/Sources/TransitionsCore, built here by src/transitions_core_fw.cpp and
// also compiled by the iOS app so it can mirror the board). Add new transitions there.
// ==================================================

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

// Name the firmware announces (TRANSITION:<name>); the table lives in the shared core.
String getTransitionName(TransitionType transition) { return String(tx_name((int)transition)); }

static TransitionType resolveRetired(TransitionType t) { return (TransitionType)tx_resolve((int)t); }

// Board side of the shared transition core: draws go to the panel, waits are real.
static void fwBitmap(void*, int16_t x, int16_t y, const uint16_t* px, int16_t w, int16_t h) {
  gfx->draw16bitRGBBitmap(x, y, (uint16_t*)px, w, h);
}
static void fwPixel(void*, int16_t x, int16_t y, uint16_t c) { gfx->drawPixel(x, y, c); }
static void fwWaitUs(void*, uint32_t us) {
  if (us >= 1000) delay(us / 1000);  // the old delay(ms) calls yielded to FreeRTOS; keep that
  if (us % 1000) delayMicroseconds(us % 1000);
}
static void* fwAllocLarge(void*, size_t bytes) { return ps_malloc(bytes); }
static const TxPanel FW_PANEL = { nullptr, fwBitmap, fwPixel, fwWaitUs, fwAllocLarge };

// Last measured draw time per transition index since boot (ms, 0 = never drawn). Sent as
// TRANSITION_START's expectedMs so the app can pace its mirror.
static uint16_t transitionLastMs[TRANSITION_COUNT] = {0};

// BLE_PROTOCOL 1.13: "a transition is starting now". Sent from loop() (via runTransition), never
// from a BLE callback. `drawn` is the index tx_run will actually draw.
static void announceTransitionStart(int drawn, uint32_t seed, bool oldBlack) {
  if (!pMsgChar) return;
  char msg[64];
  snprintf(msg, sizeof(msg), "TRANSITION_START:%d:%lu:%u:%d", drawn, (unsigned long)seed,
           (unsigned)transitionLastMs[drawn], oldBlack ? 1 : 0);
  pMsgChar->setValue(msg);
  pMsgChar->notify();
}

// Draw `buffer` (the new cover) with transition `t`. Frame-composed transitions read the old
// cover from prevBuffer. Afterwards prevBuffer holds the new cover for the next transition.
static void runTransition(TransitionType t, uint16_t* buffer, int width, int height) {
  const bool canCompose = prevBuffer && composeBuffer;
  const bool oldBlack = canCompose && !panelShowsImage;
  if (oldBlack) memset(prevBuffer, 0, IMAGE_SIZE);  // old = black, not a stale cover
  const uint16_t* oldB = canCompose ? prevBuffer : nullptr;
  // Resync the panel's drawing rectangle. Arduino_ST7789 skips CASET/RASET when the window equals
  // the last one it sent; if one of those commands was ever garbled on the wire, every later
  // same-sized draw went to the wrong rectangle (whole covers missing, single lines) until a
  // differently-sized draw happened. A 1x1 write here makes the next draw resend both. The pixel is
  // the new cover's own (0,0), which the transition paints anyway.
  gfx->drawPixel(0, 0, buffer[0]);
  const uint32_t seed = esp_random();
  // Announce what will actually draw: retired slots resolve to their twin, and without the two
  // compose buffers the frame-composed ones (>= Card Stack) fall back to Wipe Up, as in tx_run.
  int drawn = tx_resolve((int)t);
  if (drawn < 0 || drawn >= TRANSITION_COUNT || (!canCompose && drawn >= TRANSITION_CARD_STACK))
    drawn = TRANSITION_WIPE_BOTTOM;
  announceTransitionStart(drawn, seed, oldBlack);
  // The shared core (SpotifyDisplay.swiftpm/Sources/TransitionsCore) draws it, exactly as the app does.
  const unsigned long drawStart = millis();
  drawn = tx_run(&FW_PANEL, (int)t, oldB, buffer, canCompose ? composeBuffer : nullptr, seed);
  const unsigned long drawMs = millis() - drawStart;
  if (drawn >= 0 && drawn < TRANSITION_COUNT) transitionLastMs[drawn] = drawMs > 0xFFFF ? 0xFFFF : (uint16_t)drawMs;
  if (canCompose) memcpy(prevBuffer, buffer, IMAGE_SIZE);
  panelShowsImage = true;
  Serial.println("Transition complete!");
}

// True if the app left transition `t` switched on (BLE_PROTOCOL 1.12 mask).
static bool transitionEnabled(int t) {
  if (t < 0 || t >= TRANSITION_COUNT) return false;
  return t < 32 ? ((transitionMaskLo >> t) & 1u) : ((transitionMaskHi >> (t - 32)) & 1u);
}

static TransitionType pickEnabledTransition(bool quickOnly);  // defined after QUICK_TRANSITIONS

String drawImageWithRandomTransition(uint16_t* buffer, int width, int height) {
  // Pick a random live, enabled transition (skip retired slots and the last one used)
  TransitionType transition = pickEnabledTransition(false);

  lastTransition = transition;
  String transitionName = getTransitionName(transition);
  Serial.printf("Using transition: %s\n", transitionName.c_str());
  runTransition(transition, buffer, width, height);
  return transitionName;
}

// New songs have already waited ~2-3 s for their BLE transfer, so they get only the fast transitions
// (measured draw time in brackets). Cache hits keep the full set.
static const TransitionType QUICK_TRANSITIONS[] = {
  TRANSITION_RANDOM_BLOCKS,   // ~130 ms
  TRANSITION_WIPE_BOTTOM,     // ~160 ms ("Wipe Up")
  TRANSITION_VENETIAN_V,      // ~160 ms
  TRANSITION_CHECKERBOARD,    // ~240 ms
  TRANSITION_ZOOM_BLOCKS,     // ~255 ms
  TRANSITION_VERTICAL_SPLIT,  // ~315 ms
  // Threshold-map quick set: 10 composed frames each, estimated ~130-160 ms (not yet measured).
  TRANSITION_QUICK_IRIS,
  TRANSITION_DIAMOND_IRIS,
  TRANSITION_HEART_IRIS,
  TRANSITION_CLOCK_SWEEP,
  TRANSITION_BOW_TIE,
  TRANSITION_WIND,
  TRANSITION_POLKA_DOTS,
  TRANSITION_RAIN_COLUMNS,
  TRANSITION_WAVE_WIPE,
  TRANSITION_VENETIAN_H,
  TRANSITION_SPIRAL_IN,
  TRANSITION_LUMA_WIPE,
};

// Picks a random transition that is live, enabled and (when there is a choice) not the last one used.
// `quickOnly` restricts it to QUICK_TRANSITIONS; if none of those is enabled it falls back to any enabled
// one, because an explicit choice in the app beats the "fast for new songs" preference. If the mask
// leaves nothing enabled at all, everything is allowed (never get stuck without a transition).
static TransitionType pickEnabledTransition(bool quickOnly) {
  const int quickN = sizeof(QUICK_TRANSITIONS) / sizeof(QUICK_TRANSITIONS[0]);
  auto isQuick = [quickN](int t) {
    for (int i = 0; i < quickN; i++) if ((int)QUICK_TRANSITIONS[i] == t) return true;
    return false;
  };
  for (int pass = 0; pass < 3; pass++) {
    // pass 0: enabled (+quick), not the last one; pass 1: same but repeats allowed;
    // pass 2: enabled at any speed (only reached when quickOnly found nothing).
    TransitionType cand[TRANSITION_COUNT];
    int n = 0;
    for (int t = 0; t < TRANSITION_COUNT; t++) {
      if (isRetiredTransition((TransitionType)t) || !transitionEnabled(t)) continue;
      if (pass < 2 && quickOnly && !isQuick(t)) continue;
      if (pass == 0 && (TransitionType)t == lastTransition) continue;
      cand[n++] = (TransitionType)t;
    }
    if (n > 0) return cand[random(0, n)];
  }
  // Nothing enabled: allow every live transition except the last one used.
  TransitionType t;
  do { t = (TransitionType)random(0, TRANSITION_COUNT); }
  while (isRetiredTransition(t) || t == lastTransition);
  return t;
}

String drawImageWithQuickTransition(uint16_t* buffer, int width, int height) {
  TransitionType transition = pickEnabledTransition(true);
  lastTransition = transition;
  String transitionName = getTransitionName(transition);
  Serial.printf("Using transition: %s (quick, new song)\n", transitionName.c_str());
  runTransition(transition, buffer, width, height);
  return transitionName;
}

// `quick`: when no transition is forced, pick from QUICK_TRANSITIONS (fresh transfers).
String drawImageWithTransitionChoice(uint16_t* buffer, int width, int height, uint8_t transitionChoice,
                                     bool quick = false) {
  if (transitionChoice == 0xFF || transitionChoice >= (uint8_t)TRANSITION_COUNT) {
    return quick ? drawImageWithQuickTransition(buffer, width, height)
                 : drawImageWithRandomTransition(buffer, width, height);
  }

  TransitionType forced = resolveRetired((TransitionType)transitionChoice);
  String transitionName = getTransitionName(forced);
  Serial.printf("Using forced transition: %s (%u)\n", transitionName.c_str(), (unsigned)transitionChoice);
  lastTransition = forced;
  runTransition(forced, buffer, width, height);
  return transitionName;
}

// ==================================================
// BLUETOOTH CONNECTION SCREEN HELPER
// ==================================================

void showBluetoothConnectionScreen(uint16_t yesColor, uint16_t noColor) {
    panelShowsImage = false;
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

void resetToWaitingScreen() {
    panelShowsImage = false;
    showingStartupScreen = true;
    pulseIsWhite = false;
    lastPulseUpdate = millis();
    showBluetoothConnectionScreen(BLACK, RED);
}

// Connected, nothing played yet.
void showReadyScreen() {
    panelShowsImage = false;
    gfx->fillScreen(WHITE);
    gfx->setTextSize(3);
    gfx->setTextColor(BLACK);
    gfx->setCursor(39, 80);  // Centered: "Play some" = 9 chars
    gfx->print("Play some");
    gfx->setCursor(48, 110);  // Centered: "music on" = 8 chars
    gfx->print("music on");
    gfx->setCursor(48, 140);  // Centered: "Spotify!" = 8 chars
    gfx->setTextColor(SPOTIFY_GREEN);
    gfx->print("Spotify!");
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
    // Prefer LE 2M for every connection; onConnect also asks per connection. PHY changes are
    // reported through the GAP handler (runs on BTC_TASK: only copies values, loop() logs them).
    esp_ble_gap_set_prefered_default_phy(ESP_BLE_GAP_PHY_2M_PREF_MASK, ESP_BLE_GAP_PHY_2M_PREF_MASK);
    BLEDevice::setCustomGapHandler(onGapEvent);

    // Create BLE server
    pServer = BLEDevice::createServer();
    pServer->setCallbacks(new MyServerCallbacks());
    Serial.println("BLE Server created");

    // Create BLE service
    // 30 attribute handles. The default (15) is exactly used up by ffe1-ffe5 (each characteristic takes
    // 2, each CCCD 1, the service 1); a 6th characteristic would silently fail to register.
    BLEService *pService = pServer->createService(BLEUUID(SERVICE_UUID), 30, 0);
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
        BLECharacteristic::PROPERTY_WRITE_NR |
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

    // Brightness characteristic (Write) - backlight PWM level 0..255
    pBrightnessChar = pService->createCharacteristic(
        BRIGHTNESS_CHAR_UUID,
        BLECharacteristic::PROPERTY_WRITE
    );
    pBrightnessChar->setCallbacks(new BrightnessCallbacks());
    Serial.println("  + Brightness characteristic (ffe5)");

    // Status LED brightness (Write) - 0..255 of the LED's safe cap (BLE_PROTOCOL 1.13)
    BLECharacteristic* pLedChar = pService->createCharacteristic(
        STATUS_LED_CHAR_UUID,
        BLECharacteristic::PROPERTY_WRITE
    );
    pLedChar->setCallbacks(new StatusLedCallbacks());
    Serial.println("  + Status LED characteristic (ffe6)");

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
  // No startup wait for the serial monitor: it cost a full second of boot every power-on.

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
  ledcSetup(TFT_BL_PWM_CHANNEL, 5000, 8);   // 5kHz, 8-bit duty (0-255)
  ledcAttachPin(TFT_BL, TFT_BL_PWM_CHANNEL);
  // Backlight OFF until the panel has been cleared: panel RAM powers up with random pixels, and
  // with the light on they show for the ~0.3 s of reset + init below. (Driving the pin also stops
  // it floating high, which is what the old "white screen" fix was for.)
  ledcWrite(TFT_BL_PWM_CHANNEL, 0);

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
  // Clear the random power-up contents, then turn the light on (low during the ~1 s of SD init).
  gfx->fillScreen(WHITE);
  ledcWrite(TFT_BL_PWM_CHANNEL, 50);
  neopixelWrite(STATUS_LED_PIN, 0, 0, 0);  // status LED starts dark (it can latch junk at power-up)

  // Configure MADCTL register (0x36) for RGB/BGR color order
  // Using 0x00: RGB mode (matches RGB565 format from Python)
  bus->beginWrite();
  bus->writeCommand(0x36); // MADCTL
  bus->write(0x00);        // Binary: 00000000 - RGB mode
  bus->endWrite();

  // ST7789 gamma: the datasheet's typical gamma 2.2 (sRGB) curve, so covers show in native colour
  // (owner's choice 2026-11-22; the app's colour boost is off too). Values from
  // resources/st7789vw_gamma_reference.md "Default γ=2.2". The earlier "punchy" table, to go back:
  //   pos {0xD0,0x06,0x10,0x14,0x16,0x30,0x3F,0x55,0x4A,0x16,0x0C,0x0A,0x1E,0x22}
  //   neg {0xD0,0x05,0x0F,0x13,0x16,0x30,0x3E,0x47,0x53,0x30,0x20,0x20,0x21,0x24}
  const uint8_t gammaPos[] = {0xD0,0x04,0x0D,0x11,0x13,0x2B,0x3F,0x54,0x4C,0x18,0x0D,0x0B,0x1F,0x23};
  const uint8_t gammaNeg[] = {0xD0,0x04,0x0C,0x11,0x13,0x2C,0x3F,0x44,0x51,0x2F,0x1F,0x1F,0x20,0x23};
  bus->beginWrite();
  bus->writeCommand(0xE0);
  for (size_t i = 0; i < sizeof(gammaPos); i++) bus->write(gammaPos[i]);
  bus->writeCommand(0xE1);
  for (size_t i = 0; i < sizeof(gammaNeg); i++) bus->write(gammaNeg[i]);
  bus->endWrite();

  // Increase backlight to normal brightness after init complete
  ledcWrite(TFT_BL_PWM_CHANNEL, brightness);

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

  buildCacheIndex();
  Serial.printf("Cache index ready: %lu entries\n", (unsigned long)cacheEntryCount);

  Serial.println("========================================");
  Serial.println("SD CARD READY FOR CACHING");
  Serial.println("========================================\n");
  Serial.flush();

  // Pre-allocate image buffer ONCE from PSRAM to prevent heap fragmentation
  if (psramFound()) {
    imageBuffer = (uint16_t*)ps_malloc(IMAGE_SIZE);  // Allocate from PSRAM
    Serial.println("Allocating image buffer from PSRAM...");
  } else {
    imageBuffer = (uint16_t*)malloc(IMAGE_SIZE);  // Fallback to regular heap
    Serial.println("WARNING: Allocating image buffer from heap (no PSRAM)");
  }

  rxBuffer = psramFound() ? (uint16_t*)ps_malloc(IMAGE_SIZE) : (uint16_t*)malloc(IMAGE_SIZE);
  // Frame-composed transitions only; without them those transitions fall back to Wipe Up.
  if (psramFound()) {
    prevBuffer = (uint16_t*)ps_malloc(IMAGE_SIZE);
    composeBuffer = (uint16_t*)ps_malloc(IMAGE_SIZE);
  }
  Serial.printf("Compose buffers: %s\n", (prevBuffer && composeBuffer) ? "ok" : "MISSING (frame transitions disabled)");
  // Compressed transfers (1.11). Without these the board simply never advertises CAPS:deflate.
  if (psramFound()) {
    rxPacked = (uint8_t*)ps_malloc(IMAGE_SIZE);
    inflator = (tinfl_decompressor*)ps_malloc(sizeof(tinfl_decompressor));
  }
  Serial.printf("Deflate receive: %s\n", (rxPacked && inflator) ? "ok" : "MISSING (raw frames only)");

  if (!imageBuffer || !rxBuffer) {
    Serial.println("FATAL: Cannot allocate image buffers");
    Serial.flush();
    while(1) delay(1000); // Halt system - cannot continue without buffer
  }
  Serial.printf("Image buffers allocated: 2 x %d bytes (free heap: %d)\n", IMAGE_SIZE, ESP.getFreeHeap());
  Serial.flush();

  // Start BLE first so the phone can find the board while the greeting plays.
  setupBLE();

  // Greeting: "Hiii" centered (size 3 = 18x24 px per char), quick fade-in, short hold.
  gfx->fillScreen(WHITE);
  gfx->setTextSize(3);
  const int16_t hiX = (240 - 4 * 18) / 2, hiY = (240 - 24) / 2;
  for (int fadeVal = 224; fadeVal >= 0; fadeVal -= 32) {
    gfx->setTextColor(RGB565(fadeVal, fadeVal, fadeVal), WHITE);
    gfx->setCursor(hiX, hiY);
    gfx->print("Hiii");
    delay(25);
  }
  gfx->setTextColor(BLACK, WHITE);
  gfx->setCursor(hiX, hiY);
  gfx->print("Hiii");
  delay(1500);

  // If the phone already connected during the greeting, loop() draws the connected UI;
  // otherwise show the waiting screen.
  showBluetoothConnectionScreen(BLACK, RED);


  Serial.println("SETUP COMPLETE - BLE MODE ACTIVE.");
  Serial.flush();
}

void flushSerialInput() {
  while (Serial.available()) {
    Serial.read();
  }
}

String getCacheFileNameVersioned(const uint8_t* cacheKey, uint8_t version) {
  char filename[48];
  sprintf(filename, "/cache/v%u_"
          "%02X%02X%02X%02X%02X%02X%02X%02X"
          "%02X%02X%02X%02X%02X%02X%02X%02X.bin",
          (unsigned)version,
          cacheKey[0], cacheKey[1], cacheKey[2], cacheKey[3],
          cacheKey[4], cacheKey[5], cacheKey[6], cacheKey[7],
          cacheKey[8], cacheKey[9], cacheKey[10], cacheKey[11],
          cacheKey[12], cacheKey[13], cacheKey[14], cacheKey[15]);
  return String(filename);
}

// Backward-compatible legacy name (no version prefix).
String getLegacyCacheFileName(const uint8_t* cacheKey) {
  char filename[44];
  sprintf(filename, "/cache/"
          "%02X%02X%02X%02X%02X%02X%02X%02X"
          "%02X%02X%02X%02X%02X%02X%02X%02X.bin",
          cacheKey[0], cacheKey[1], cacheKey[2], cacheKey[3],
          cacheKey[4], cacheKey[5], cacheKey[6], cacheKey[7],
          cacheKey[8], cacheKey[9], cacheKey[10], cacheKey[11],
          cacheKey[12], cacheKey[13], cacheKey[14], cacheKey[15]);
  return String(filename);
}

bool parseCacheFilenameToKey(const String& path, uint8_t* outKey, uint8_t* outVersion) {
  String name = path;
  int slash = name.lastIndexOf('/');
  if (slash >= 0) name = name.substring(slash + 1);
  if (!name.endsWith(".bin")) return false;

  uint8_t version = 0;
  String hexPart;
  if (name.startsWith("v")) {
    int underscore = name.indexOf('_');
    if (underscore < 2) return false;
    String ver = name.substring(1, underscore);
    for (size_t i = 0; i < ver.length(); i++) {
      if (!isdigit((unsigned char)ver[i])) return false;
    }
    version = (uint8_t)ver.toInt();
    hexPart = name.substring(underscore + 1, name.length() - 4);
  } else {
    hexPart = name.substring(0, name.length() - 4);
  }
  if (hexPart.length() != 32) return false;
  for (int i = 0; i < 16; i++) {
    char c1 = hexPart[i * 2];
    char c2 = hexPart[i * 2 + 1];
    if (!isxdigit((unsigned char)c1) || !isxdigit((unsigned char)c2)) return false;
    char pair[3] = {c1, c2, '\0'};
    outKey[i] = (uint8_t)strtoul(pair, nullptr, 16);
  }
  *outVersion = version;
  return true;
}

void clearCacheIndex() {
  for (size_t i = 0; i < CACHE_INDEX_MAX_ENTRIES; i++) {
    cacheIndex[i].used = false;
  }
  cacheEntryCount = 0;
}

bool cacheIndexContains(const uint8_t* cacheKey) {
  for (size_t i = 0; i < CACHE_INDEX_MAX_ENTRIES; i++) {
    if (cacheIndex[i].used && memcmp(cacheIndex[i].key, cacheKey, 16) == 0) {
      return true;
    }
  }
  return false;
}

bool cacheIndexInsert(const uint8_t* cacheKey) {
  if (cacheIndexContains(cacheKey)) return true;
  for (size_t i = 0; i < CACHE_INDEX_MAX_ENTRIES; i++) {
    if (!cacheIndex[i].used) {
      memcpy(cacheIndex[i].key, cacheKey, 16);
      cacheIndex[i].used = true;
      cacheEntryCount++;
      return true;
    }
  }
  return false;
}

bool cacheIndexRemove(const uint8_t* cacheKey) {
  for (size_t i = 0; i < CACHE_INDEX_MAX_ENTRIES; i++) {
    if (cacheIndex[i].used && memcmp(cacheIndex[i].key, cacheKey, 16) == 0) {
      cacheIndex[i].used = false;
      if (cacheEntryCount > 0) cacheEntryCount--;
      return true;
    }
  }
  return false;
}

void buildCacheIndex() {
  clearCacheIndex();
  File root = SD.open("/cache");
  if (!root || !root.isDirectory()) {
    if (root) root.close();
    return;
  }
  // getNextFileName() reads the directory entry without opening each file. openNextFile() opened
  // every cache file and took ~45 ms apiece (337 files = 15 s of boot).
  for (;;) {
    bool isDir = false;
    String name = root.getNextFileName(&isDir);
    if (name.length() == 0) break;
    if (isDir) continue;
    uint8_t key[16];
    uint8_t version = 0;
    if (parseCacheFilenameToKey(name, key, &version) && (version == 0 || version == CACHE_KEY_VERSION)) {
      if (!cacheIndexInsert(key)) {
        Serial.println("WARN: Cache index full; fallback to SD.exists for extra files");
      }
    }
  }
  root.close();
}

bool removeCacheFileAndIndex(const String& filename, const uint8_t* cacheKey) {
  bool removed = SD.remove(filename);
  if (removed && cacheKey) {
    cacheIndexRemove(cacheKey);
    cacheRecoveries++;
  }
  return removed;
}

// Check if image exists in cache index; fallback to SD.exists if index evicted/full.
bool isCached(uint8_t* cacheKey) {
  if (cacheIndexContains(cacheKey)) return true;
  if (SD.exists(getCacheFileNameVersioned(cacheKey, CACHE_KEY_VERSION))) return true;
  if (SD.exists(getLegacyCacheFileName(cacheKey))) return true;
  return false;
}

uint32_t computeCRC32(const uint8_t* data, size_t len) {
  uint32_t crc = 0xFFFFFFFFu;
  for (size_t i = 0; i < len; i++) {
    crc ^= data[i];
    for (int b = 0; b < 8; b++) {
      uint32_t mask = -(crc & 1u);
      crc = (crc >> 1) ^ (0xEDB88320u & mask);
    }
  }
  return ~crc;
}

// Load image from SD card cache
bool loadFromCache(uint8_t* cacheKey) {
  unsigned long startTime = millis();

  String filename = getCacheFileNameVersioned(cacheKey, CACHE_KEY_VERSION);
  if (!SD.exists(filename)) {
    filename = getLegacyCacheFileName(cacheKey);
  }
  File file = SD.open(filename, FILE_READ);

  if (!file) {
    Serial.println("ERROR: Cache file not found");
    return false;
  }

  size_t fileSize = file.size();
  const size_t expectedWithCRC = IMAGE_SIZE + 4;
  if (fileSize != IMAGE_SIZE && fileSize != expectedWithCRC) {
    Serial.printf("ERROR: Cache size mismatch %d\n", (int)fileSize);
    file.close();
    removeCacheFileAndIndex(filename, cacheKey);
    return false;
  }

  // Read directly into image buffer
  size_t bytesRead = file.read((uint8_t*)imageBuffer, IMAGE_SIZE);
  if (bytesRead != IMAGE_SIZE) {
    Serial.printf("ERROR: Cache read failed %d\n", bytesRead);
    file.close();
    removeCacheFileAndIndex(filename, cacheKey);
    return false;
  }

  if (fileSize == expectedWithCRC) {
    uint8_t crcBytes[4];
    size_t crcRead = file.read(crcBytes, 4);
    if (crcRead != 4) {
      Serial.println("ERROR: Cache CRC read failed");
      file.close();
      cacheCRCErrors++;
      removeCacheFileAndIndex(filename, cacheKey);
      return false;
    }
    uint32_t expectedCrc = (uint32_t)crcBytes[0]
                         | ((uint32_t)crcBytes[1] << 8)
                         | ((uint32_t)crcBytes[2] << 16)
                         | ((uint32_t)crcBytes[3] << 24);
    uint32_t actualCrc = computeCRC32((uint8_t*)imageBuffer, IMAGE_SIZE);
    if (actualCrc != expectedCrc) {
      Serial.printf("ERROR: Cache CRC mismatch expected=0x%08lX actual=0x%08lX\n",
                    (unsigned long)expectedCrc, (unsigned long)actualCrc);
      file.close();
      cacheCRCErrors++;
      removeCacheFileAndIndex(filename, cacheKey);
      return false;
    }
  }
  file.close();
  cacheIndexInsert(cacheKey);

  unsigned long loadTime = millis() - startTime;
  Serial.printf("Cache HIT: %s (load: %lums)\n", filename.c_str(), loadTime);
  return true;
}

// Save image to SD card cache
bool saveToCache(uint8_t* cacheKey, const uint16_t* src) {
  if (!src) src = imageBuffer;
  String filename = getCacheFileNameVersioned(cacheKey, CACHE_KEY_VERSION);
  String tmpFilename = filename + ".tmp";

  SD.remove(tmpFilename);

  File file = SD.open(tmpFilename, FILE_WRITE);
  if (!file) {
    Serial.println("ERROR: Cannot create cache file");
    return false;
  }

  size_t bytesWritten = file.write((const uint8_t*)src, IMAGE_SIZE);
  uint32_t crc = computeCRC32((const uint8_t*)src, IMAGE_SIZE);
  uint8_t crcLE[4] = {
    (uint8_t)(crc & 0xFF),
    (uint8_t)((crc >> 8) & 0xFF),
    (uint8_t)((crc >> 16) & 0xFF),
    (uint8_t)((crc >> 24) & 0xFF)
  };
  size_t crcWritten = file.write(crcLE, 4);
  file.flush();
  file.close();

  if (bytesWritten != IMAGE_SIZE || crcWritten != 4) {
    Serial.printf("ERROR: Cache write failed image=%d crc=%d\n", (int)bytesWritten, (int)crcWritten);
    SD.remove(tmpFilename); // Remove incomplete file
    return false;
  }

  if (SD.exists(filename)) {
    SD.remove(filename);
  }
  if (!SD.rename(tmpFilename, filename)) {
    Serial.println("ERROR: Cache atomic rename failed");
    SD.remove(tmpFilename);
    return false;
  }

  cacheIndexInsert(cacheKey);
  enforceCacheCapacityHook();
  Serial.printf("Cache SAVE: %s\n", filename.c_str());
  return true;
}

// Count *.bin files in /cache (for BLE CACHE_COUNT message)
static uint32_t countCacheBinFiles() {
  return cacheEntryCount;
}

void publishCacheCount() {
  String msg = "CACHE_COUNT:" + String((unsigned long)countCacheBinFiles());
  pMsgChar->setValue(msg.c_str());
  pMsgChar->notify();
  Serial.printf("BLE: %s\n", msg.c_str());
}

void publishCacheStats() {
  String msg = "CACHE_HEALTH:count=" + String((unsigned long)countCacheBinFiles()) +
               ",crc=" + String((unsigned long)cacheCRCErrors) +
               ",recoveries=" + String((unsigned long)cacheRecoveries) +
               ",ver=" + String((unsigned long)CACHE_KEY_VERSION);
  pMsgChar->setValue(msg.c_str());
  pMsgChar->notify();
  Serial.printf("BLE: %s\n", msg.c_str());
}

// Phase B hook: firmware owns capacity policy; currently no-op until product limits are chosen.
void enforceCacheCapacityHook() {}

void clearCacheDirectory() {
  unsigned long start = millis();
  File root = SD.open("/cache");
  if (!root || !root.isDirectory()) {
    if (root) root.close();
    clearCacheIndex();
    return;
  }
  uint32_t removed = 0;
  for (;;) {
    File f = root.openNextFile();
    if (!f) break;
    if (!f.isDirectory()) {
      String name = String(f.name());
      name.toLowerCase();
      if (name.endsWith(".bin")) {
        String path = String(f.name());
        uint8_t key[16];
        uint8_t version = 0;
        if (parseCacheFilenameToKey(path, key, &version)) {
          if (SD.remove(path)) {
            cacheIndexRemove(key);
            removed++;
          }
        } else if (SD.remove(path)) {
          removed++;
        }
      }
    }
    f.close();
  }
  root.close();
  clearCacheIndex();
  unsigned long elapsed = millis() - start;
  Serial.printf("Cache clear complete: removed=%lu elapsed=%lums\n", (unsigned long)removed, elapsed);
}

// ============================================================================
// Status LED — the board's WS2812B on GPIO15 (Waveshare ESP32-S3; was unused).
// Driven ONLY from loop(): neopixelWrite() uses the RMT peripheral and must not run on the tiny
// BTC_TASK stack. Callbacks only set flags / counters that loop() already reads.
//   cache check / cache hit drawing  -> blue
//   new cover arriving over BLE      -> orange, pulsing, brighter as the frame fills
//   frame drawn + saved + ACKed      -> green flash, then fade to off
//   transfer rejected                -> two dim red blinks
//   idle / just showing a cover      -> off
// Prefetch (store-only) transfers and prefetch probes stay dark: the song on screen isn't changing.
// ============================================================================
#define STATUS_LED_MAX 120  // ceiling out of 255 (~47%). Owner: as bright as reasonable, under 50%
                            // (2026-11-22). Only lit ~1-2 s per song, ~10 mA: no real heat.
// A cache miss means a cover is coming, but the phone first downloads and dithers it (~0.5-1.5 s).
// The LED goes orange right away (LED_WAITING) instead of sitting dark; if nothing arrives in this
// long (skip, phone gave up), it goes off.
#define LED_WAITING_TIMEOUT_MS 4000

#define LED_RGB_BLUE   0x0050FF
#define LED_RGB_ORANGE 0xFF5A00
#define LED_RGB_GREEN  0x00FF28
#define LED_RGB_RED    0xFF0000

enum LedMode : uint8_t { LED_OFF, LED_CACHE, LED_WAITING, LED_TRANSFER, LED_DONE, LED_ERROR };
static LedMode ledMode = LED_OFF;
static unsigned long ledModeSince = 0;
static uint32_t ledLastWritten = 0xFFFFFFFF;

static void ledWriteRaw(uint8_t r, uint8_t g, uint8_t b) {
  uint32_t c = ((uint32_t)r << 16) | ((uint32_t)g << 8) | b;
  if (c == ledLastWritten) return;  // skip redundant RMT writes (loop runs ~100x/s)
  ledLastWritten = c;
  neopixelWrite(STATUS_LED_PIN, r, g, b);  // core handles the WS2812 GRB byte order
}

// level 0..255 is scaled into 0..STATUS_LED_MAX, then by the app's status-light setting.
static void ledShow(uint32_t rgb, uint16_t level) {
  uint32_t k = (uint32_t)level * STATUS_LED_MAX / 255 * statusLedLevel / 255;
  ledWriteRaw((uint8_t)(((rgb >> 16) & 0xFF) * k / 255),
              (uint8_t)(((rgb >> 8) & 0xFF) * k / 255),
              (uint8_t)((rgb & 0xFF) * k / 255));
}

static void ledUpdate() {
  unsigned long t = millis() - ledModeSince;
  switch (ledMode) {
    case LED_OFF:
      ledWriteRaw(0, 0, 0);
      break;
    case LED_CACHE:
      ledShow(LED_RGB_BLUE, 255);  // solid while the SD lookup / cache-hit draw blocks loop()
      break;
    case LED_WAITING:  // same orange pulse at the 0% brightness (receivedBytes is 0 here)
      if (t >= LED_WAITING_TIMEOUT_MS) { ledMode = LED_OFF; ledWriteRaw(0, 0, 0); break; }
      // fall through
    case LED_TRANSFER: {
      // Base brightness follows progress (40% -> 100%); a 1.2 s triangle pulse rides on top.
      // Progress is against this frame's wire size: a compressed frame (1.11) is smaller than
      // IMAGE_SIZE. Both are written on BTC_TASK; a torn read only nudges brightness.
      uint32_t want = expectedSize;
      if (want == 0 || want > IMAGE_SIZE) want = IMAGE_SIZE;
      uint32_t got = ledMode == LED_WAITING ? 0 : receivedBytes;
      if (got > want) got = want;
      uint32_t base = 100 + (got * 155) / want;
      uint32_t phase = t % 1200;
      uint32_t tri = phase < 600 ? phase : 1200 - phase;  // 0..600
      uint32_t pulse = 150 + (tri * 105) / 600;            // 150..255
      ledShow(LED_RGB_ORANGE, (uint16_t)(base * pulse / 255));
      break;
    }
    case LED_DONE:
      if (t < 220) ledShow(LED_RGB_GREEN, 255);
      else if (t < 720) ledShow(LED_RGB_GREEN, (uint16_t)(255 - (t - 220) * 255 / 500));
      else { ledMode = LED_OFF; ledWriteRaw(0, 0, 0); }
      break;
    case LED_ERROR:
      if (t < 450) ledShow(LED_RGB_RED, ((t / 150) % 2) ? 0 : 140);  // on-off-on
      else { ledMode = LED_OFF; ledWriteRaw(0, 0, 0); }
      break;
  }
}

static void ledSetMode(LedMode m) {
  ledMode = m;
  ledModeSince = millis();
  ledUpdate();  // show it now: the caller may be about to block on SD or a transition
}

// Once per loop(): pick up callback-side state, then animate.
static void ledPoll() {
  if (ledErrorPending) {
    ledErrorPending = false;
    ledSetMode(LED_ERROR);
  }
  bool receiving = deviceConnected && imageState == RECEIVING_DATA &&
                   pendingTransition != TRANSITION_STORE_ONLY;
  if (receiving && ledMode != LED_TRANSFER && ledMode != LED_ERROR) {
    ledSetMode(LED_TRANSFER);
  } else if (!receiving && ledMode == LED_TRANSFER && !imageTransferComplete) {
    ledSetMode(LED_OFF);  // frame abandoned (skip / resync / disconnect)
  }
  ledUpdate();
}

void loop() {
  ledPoll();

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

  if (phyUpdatePending) {
    phyUpdatePending = false;
    // 1 = LE 1M, 2 = LE 2M, 3 = Coded
    Serial.printf("BLE: PHY tx=%uM rx=%uM (status %u)\n", (unsigned)phyTx, (unsigned)phyRx, (unsigned)phyStatus);
  }

  if (dleUpdatePending) {
    dleUpdatePending = false;
    Serial.printf("BLE: Data length tx=%u rx=%u bytes (status %u)\n", (unsigned)dleTx, (unsigned)dleRx,
                  (unsigned)dleStatus);
  }

  if (connParamsPending) {
    connParamsPending = false;
    unsigned units = connIntervalUnits;
    Serial.printf("BLE: Connection interval %u.%02u ms (status %u)\n", (units * 125) / 100,
                  (units * 125) % 100, (unsigned)connParamsStatus);
    // Refused, or iOS kept something slower than 15 ms: ask once for the compliant 15 ms.
    if (deviceConnected && peerAddrValid && !connIntervalFallbackSent &&
        (connParamsStatus != 0 || units > CONN_INT_SAFE)) {
      connIntervalFallbackSent = true;
      pServer->updateConnParams(peerAddr, CONN_INT_SAFE, CONN_INT_SAFE, 0, CONN_SUPERVISION_TIMEOUT);
      Serial.println("BLE: Falling back to 15 ms connection interval request");
    }
  }

  // BLE stats: number of /cache/*.bin files — sent to the phone app only (never drawn on this display)
  if (statsRequestPending) {
    statsRequestPending = false;
    // BLE_PROTOCOL 1.11: tells the app it may send deflate-compressed frames (10-byte header).
    // Sent before CACHE_COUNT, which the app awaits right after connecting.
    if (rxPacked && inflator) {
      pMsgChar->setValue("CAPS:deflate");
      pMsgChar->notify();
    }
    // BLE_PROTOCOL 1.12: the board understands the enabled-transitions mask and the 0xFD display-only
    // header byte, and announces TRANSITION:<name> after fresh draws too.
    pMsgChar->setValue("CAPS:transitions");
    pMsgChar->notify();
    publishCacheCount();
    publishCacheStats();
  }

  if (clearCachePending) {
    clearCachePending = false;
    unsigned long clearStart = millis();
    clearCacheDirectory();
    String msg = "CACHE_CLEARED";
    pMsgChar->setValue(msg.c_str());
    pMsgChar->notify();
    publishCacheCount();
    unsigned long clearElapsed = millis() - clearStart;
    String timing = "CACHE_CLEAR_MS:" + String((unsigned long)clearElapsed);
    pMsgChar->setValue(timing.c_str());
    pMsgChar->notify();
    Serial.println("BLE: CACHE_CLEARED");
  }

  // Handle cache check (triggered by lightweight callback)
  // This runs in main task with large stack - safe for SD card/display ops
  // A finished transfer still waiting for its final draw + SD save owns imageBuffer: a cache hit
  // here would load another image over it before it is saved. Leave the check pending; the
  // completion block below runs this iteration and the check runs on the next one.
  if (cacheCheckPending && !imageTransferComplete) {
    cacheCheckPending = false;

    Serial.println("Processing cache check request...");

    // If a previous BLE image was abandoned mid-chunk (e.g. app skipped tracks), clear receive
    // state before cache hit/miss so a late completion cannot fire for the abandoned frame.
    if (imageState == RECEIVING_DATA) {
      Serial.println("BLE: Cache check — clearing partial image receive state");
      imageState = WAITING_FOR_SIZE;
      receivedBytes = 0;
      expectedSize = 0;
      imageTransferComplete = false;
      completedImageBytes = 0;
      rxCompressed = false;
      pendingTransition = 0xFF;  // drop a cut-off prefetch's store-only marker
    }

    if (cacheProbeOnly) {
      // Prefetch probe: answer only. Never load or draw — the screen keeps the current song.
      cacheProbeOnly = false;
      bool have = isCached(currentCacheKey);
      Serial.printf("BLE: Prefetch probe — %s\n", have ? "already cached" : "not cached");
      uint8_t response = have ? 0x01 : 0x00;
      pCacheChar->setValue(&response, 1);
      pCacheChar->notify();
    } else {

    ledSetMode(LED_CACHE);

    // Check if image is cached
    unsigned long cacheCheckStart = millis();
    cacheHit = isCached(currentCacheKey);
    unsigned long cacheCheckMs = millis() - cacheCheckStart;
    Serial.printf("Cache lookup: %lums (hit=%d)\n", cacheCheckMs, cacheHit ? 1 : 0);

    if (cacheHit) {
      unsigned long totalStartTime = millis();
      Serial.println("BLE: Cache HIT");

      // Load and display cached image
      if (loadFromCache(currentCacheKey)) {
        // Hide startup screen when displaying image
        showingStartupScreen = false;

        // NOTE: No dither on ESP — cache files were written from phone-dithered RGB565 in the BLE
        // `imageTransferComplete` path (`saveToCache`), so SD matches what the phone sent.

        // Draw image with random transition
        unsigned long displayStart = millis();
        String transitionName = drawImageWithTransitionChoice(imageBuffer, DISPLAY_WIDTH, DISPLAY_HEIGHT, pendingTransition);
        unsigned long displayTime = millis() - displayStart;

        unsigned long totalTime = millis() - totalStartTime;
        Serial.printf("⚡ Cache hit total: %lums (display: %lums)\n", totalTime, displayTime);
        String hitTiming = "CACHE_HIT_MS:" + String((unsigned long)totalTime);
        pMsgChar->setValue(hitTiming.c_str());
        pMsgChar->notify();

        // Send transition name FIRST (before cache response)
        // This ensures Python receives it before printing the cache hit message
        String transitionMsg = "TRANSITION:" + transitionName;
        pMsgChar->setValue(transitionMsg.c_str());
        pMsgChar->notify();
        delay(10);  // Small delay to ensure message is sent before cache response

        // Authoritative cache-hit render confirmation for app-side reliability.
        pMsgChar->setValue("CACHE_RENDERED");
        pMsgChar->notify();
        delay(5);

        // Notify CACHED response AFTER drawing completes
        // This prevents Python from sending new data while we're still drawing
        uint8_t response = 0x01;
        pCacheChar->setValue(&response, 1);
        pCacheChar->notify();

        // Send SUCCESS message
        pMsgChar->setValue("SUCCESS");
        pMsgChar->notify();
        ledSetMode(LED_DONE);
      } else {
        ledSetMode(LED_WAITING);  // a fresh transfer follows
        Serial.println("ERROR: Cache load failed — reporting miss so the client sends fresh");
        // The client is waiting on the Cache characteristic, not the Image one; without this
        // reply it times out instead of falling back to a normal transfer.
        uint8_t response = 0x00;
        pCacheChar->setValue(&response, 1);
        pCacheChar->notify();
      }
    } else {
      Serial.println("BLE: Cache MISS");
      ledSetMode(LED_WAITING);  // orange now, while the phone downloads + converts the cover
      String missTiming = "CACHE_MISS_MS:" + String((unsigned long)cacheCheckMs);
      pMsgChar->setValue(missTiming.c_str());
      pMsgChar->notify();

      // Notify: NEED (0x00)
      uint8_t response = 0x00;
      pCacheChar->setValue(&response, 1);
      pCacheChar->notify();
    }
    }  // not a probe
  }

  // Handle image transfer complete (triggered by lightweight callback)
  // This runs in main task with large stack - safe for SD card/display ops
  // While a frame is arriving nothing is drawn: the old picture stays up, and a transfer cut off by
  // a skip never reaches the screen. The new song appears only here, whole, with a transition.
  if (imageTransferComplete) {
    imageTransferComplete = false;

    Serial.println("Processing image transfer completion...");

    bool frameOk = true;
    if (completedCompressed) {
      completedCompressed = false;
      unsigned long inflateStart = millis();
      size_t outBytes = 0;
      frameOk = inflateFrame(rxPacked, completedImageBytes, (uint8_t*)rxBuffer, &outBytes);
      Serial.printf("BLE: Inflated %u -> %u bytes in %lums (%s)\n", (unsigned)completedImageBytes,
                    (unsigned)outBytes, millis() - inflateStart, frameOk ? "ok" : "FAILED");
    }

    if (!frameOk) {
      // Nothing drawn or saved: the old picture stays up and the app resends the frame raw.
      pendingTransition = 0xFF;
      completedImageBytes = 0;
      notifyImageTransferRejected("ERROR: Decompress failed");
    } else if (pendingTransition == TRANSITION_STORE_ONLY) {
      // Prefetched cover for a song that isn't playing yet: save it from rxBuffer, leave the
      // panel and imageBuffer alone. When that song starts, its cache check is a hit.
      pendingTransition = 0xFF;
      unsigned long saveStart = millis();
      saveToCache(transferCacheKey, rxBuffer);
      Serial.printf("BLE: Prefetch stored (not drawn), save %lums\n", millis() - saveStart);
      // ACK on the Image characteristic only. No Message "SUCCESS": that string also confirms a
      // cache-hit render in the app, and a late one could be credited to the next real song.
      uint8_t success = 0x01;
      pImageChar->setValue(&success, 1);
      pImageChar->notify();
      completedImageBytes = 0;
    } else {

    // Do NOT notify the client until display/save finish — otherwise the phone
    // can start the next BLE image while we still mutate imageBuffer (race → half frames / retries).
    // RGB565 is already Atkinson-dithered on the phone before BLE send; no dithering here.

    // The frame is whole: it becomes the picture on the panel (and what saveToCache writes).
    memcpy(imageBuffer, rxBuffer, IMAGE_SIZE);
    showingStartupScreen = false;

    // 1.12: a photo upload is shown but never written to SD.
    const bool displayOnly = (pendingTransition == TRANSITION_DISPLAY_ONLY);
    unsigned long displayStart = millis();
    String transitionName = drawImageWithTransitionChoice(imageBuffer, DISPLAY_WIDTH, DISPLAY_HEIGHT,
                                                          pendingTransition, /*quick=*/true);
    unsigned long displayTime = millis() - displayStart;
    pendingTransition = 0xFF;  // a later cache hit must not inherit this frame's header byte
    // Green as soon as the cover is on screen, not after the SD save (~0.4 s later).
    ledSetMode(LED_DONE);

    unsigned long saveStart = millis();
    if (!displayOnly) saveToCache(transferCacheKey);
    unsigned long saveTime = millis() - saveStart;

    // 1.12: tell the app which transition just ran (cache hits already do), before the ACK.
    String freshTransitionMsg = "TRANSITION:" + transitionName;
    pMsgChar->setValue(freshTransitionMsg.c_str());
    pMsgChar->notify();
    delay(5);

    Serial.printf("⚡ Processing: %s draw %lums, save %lums\n", transitionName.c_str(), displayTime, saveTime);
    Serial.println("Image processing complete!");

    // Client may send the next image only after this point (imageBuffer exclusive use ends here).
    Serial.println("BLE: Signaling SUCCESS (post-processing — safe for next transfer)");
    uint8_t success = 0x01;
    pImageChar->setValue(&success, 1);
    pImageChar->notify();

    pMsgChar->setValue("SUCCESS");
    pMsgChar->notify();

    completedImageBytes = 0;
    }  // not store-only
  }

  // Handle BLE connection state changes
  if (!deviceConnected && oldDeviceConnected) {
    // Client just disconnected
    ledSetMode(LED_OFF);
    resetToWaitingScreen();
    pServer->startAdvertising();  // Restart advertising
    Serial.println("BLE: Restarted advertising after disconnect");
    Serial.println("Display reset to waiting state");
    oldDeviceConnected = deviceConnected;
  }

  if (deviceConnected && !oldDeviceConnected) {
    // Client just connected
    oldDeviceConnected = deviceConnected;
    connIntervalFallbackSent = false;

    showingStartupScreen = false;
    // BLE starts before the boot greeting, so the phone can connect and get its cover drawn (cache
    // hit or transfer, both handled earlier in this same loop() pass) before we get here. Drawing the
    // "Play some music" screen then would cover the song, and the app (which got its ACK) would not
    // resend until the next skip. Only show the connected/ready screens when no cover is up.
    if (!panelShowsImage) {
      // Update to connected state (yes=green, no=black - connected!)
      showBluetoothConnectionScreen(GREEN, BLACK);

      // Clear and show ready message - LARGER & CENTERED
      showReadyScreen();
    } else {
      Serial.println("BLE: Connected with a cover already drawn — keeping it");
    }

    uint16_t mtu = pServer->getPeerMTU(pServer->getConnId());
    Serial.printf("BLE: Negotiated MTU = %d bytes\n", mtu);
    if (mtu < 200) {
      Serial.println("WARNING: Low MTU (" + String(mtu) + "); transfers will be slower.");
    }
    Serial.println("BLE: Client connected, ready for data");
  }

  if (deviceConnected && millis() - lastHeartbeatMs >= HEARTBEAT_INTERVAL_MS) {
    lastHeartbeatMs = millis();
    pMsgChar->setValue("HB");
    pMsgChar->notify();
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
