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
#define TFT_BRIGHTNESS_MAX 200
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
// BLE_PROTOCOL 1.13: bits 64-127 live in the former padding. Only trusted when bit 127 is set (the app's
// "this is a 128-bit mask" flag); a 1.12 app sends zeros there and must not switch indices 64+ off.
static volatile uint32_t transitionMaskW2 = 0xFFFFFFFFu;
static volatile uint32_t transitionMaskW3 = 0xFFFFFFFFu;

// Transition effects enum. Values are the BLE header's transitionIndex (docs/BLE_PROTOCOL.md),
// so they are fixed: never renumber. Retired slots stay reserved and draw their twin when forced.
enum TransitionType {
  TRANSITION_WIPE_BOTTOM = 0,     // Bottom to top
  TRANSITION_WIPE_LEFT = 1,       // Left to right
  TRANSITION_WIPE_RIGHT = 2,      // Right to left
  TRANSITION_CIRCULAR = 3,        // Expand from center
  TRANSITION_CHECKERBOARD = 4,    // Dissolve pattern
  TRANSITION_RETIRED_SLIDE = 5,   // Was "Slide": identical to Wipe Left
  TRANSITION_DIAGONAL = 6,        // Diagonal wipe
  TRANSITION_DIAGONAL_INVERSE = 7,  // Diagonal wipe (bottom-right to top-left)
  TRANSITION_VENETIAN_V = 8,      // Venetian blinds vertical
  TRANSITION_FOUR_CORNER = 9,     // Wipe from all 4 corners
  TRANSITION_RETIRED_CURTAIN = 10, // Was "Curtain": identical to Vertical Split
  TRANSITION_ZOOM_BLOCKS = 11,    // Zoom from center outward
  TRANSITION_HORIZONTAL_SPLIT = 12, // Split from center horizontally
  TRANSITION_VERTICAL_SPLIT = 13, // Split from center vertically
  TRANSITION_BARN_DOORS = 14,     // Barn doors open from center
  TRANSITION_RANDOM_BLOCKS = 15,  // Random block reveal
  TRANSITION_RETIRED_ZIGZAG = 16, // Was "Zigzag": same picture as Barn Doors
  TRANSITION_CHECKER_CASCADE = 17, // Checkerboard rippling diagonally
  TRANSITION_CARD_STACK = 18,     // New cover slides over the old one from the right
  TRANSITION_STATIC_DISSOLVE = 19, // Fine random dissolve
  TRANSITION_DITHER_FADE = 20,    // Ordered (Bayer) dither fade
  TRANSITION_PUSH_LEFT = 21,      // New cover pushes the old one out to the left
  TRANSITION_CROSSFADE = 22,      // Smooth blend
  TRANSITION_CARD_FLIP = 23,      // Whole cover flips like a card
  TRANSITION_TILE_FLIP = 24,      // 6x6 tiles flip in a diagonal wave
  TRANSITION_BLOCK_DROP = 25,     // 40 px blocks fall into place, bottom row first
  TRANSITION_MELT = 26,           // Old cover drips down in columns
  TRANSITION_ZOOM_PUNCH = 27,     // New cover zooms in with a small overshoot
  TRANSITION_CORNER_PEEL = 28,  // Corner Peel
  TRANSITION_SHATTER = 29,  // Shatter
  TRANSITION_CUBE_TURN = 30,  // Cube Turn
  TRANSITION_JELLY_DROP = 31,  // Jelly Drop
  TRANSITION_TILE_SPIN = 32,  // Tile Spin
  TRANSITION_INFINITE_ZOOM = 33,  // Infinite Zoom
  TRANSITION_RGB_SPLIT = 34,  // RGB Split
  TRANSITION_ACCORDION = 35,  // Accordion
  TRANSITION_INK_BLEED = 36,  // Ink Bleed
  TRANSITION_CRACK_SPLIT = 37,  // Crack Split
  TRANSITION_SAND_PILE = 38,  // Sand Pile
  TRANSITION_HALFTONE = 39,  // Halftone
  TRANSITION_QUICK_IRIS = 40,  // Quick Iris (quick)
  TRANSITION_DIAMOND_IRIS = 41,  // Diamond Iris (quick)
  TRANSITION_HEART_IRIS = 42,  // Heart Iris (quick)
  TRANSITION_CLOCK_SWEEP = 43,  // Clock Sweep (quick)
  TRANSITION_BOW_TIE = 44,  // Bow Tie (quick)
  TRANSITION_WIND = 45,  // Wind (quick)
  TRANSITION_POLKA_DOTS = 46,  // Polka Dots (quick)
  TRANSITION_RAIN_COLUMNS = 47,  // Rain Columns (quick)
  TRANSITION_WAVE_WIPE = 48,  // Wave Wipe (quick)
  TRANSITION_VENETIAN_H = 49,  // Venetian H (quick)
  TRANSITION_SPIRAL_IN = 50,  // Spiral In (quick)
  TRANSITION_LUMA_WIPE = 51,  // Luma Wipe (quick)
  // 1.13: 52-80 are threshold-map variants (VARIANTS table: inverses, mirrors, neon edges; quick),
  // 81-88 mirrored frame-composed effects, 89-96 zoom-outs and 2000s-tech effects.
  TRANSITION_VARIANT_FIRST = 52,
  TRANSITION_VARIANT_LAST = 80,
  TRANSITION_PUSH_RIGHT = 81,
  TRANSITION_CARD_STACK_LEFT = 82,
  TRANSITION_CUBE_TURN_REVERSE = 83,
  TRANSITION_CORNER_PEEL_REVERSE = 84,
  TRANSITION_ACCORDION_REVERSE = 85,
  TRANSITION_BLOCK_RISE = 86,
  TRANSITION_MELT_UP = 87,
  TRANSITION_JELLY_RISE = 88,
  TRANSITION_ZOOM_OUT = 89,
  TRANSITION_INFINITE_ZOOM_OUT = 90,
  TRANSITION_CRT_OFF = 91,
  TRANSITION_MATRIX_RAIN = 92,
  TRANSITION_NEON_SCAN = 93,
  TRANSITION_GLASS_SWEEP = 94,
  TRANSITION_PIXELATE = 95,
  TRANSITION_VHS_GLITCH = 96,
  TRANSITION_CUBE_UP = 97,
  TRANSITION_CUBE_DOWN = 98,
  TRANSITION_COUNT              // Total number of slots (including retired)
};

static inline bool isRetiredTransition(TransitionType t) {
  return t == TRANSITION_RETIRED_SLIDE || t == TRANSITION_RETIRED_CURTAIN ||
         t == TRANSITION_RETIRED_ZIGZAG ||
         (t >= 75 && t <= 80) ||  // neon edges: owner didn't want them (2026-11-22)
         t == TRANSITION_MATRIX_RAIN;  // owner didn't like it (2026-11-22)
}

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
void drawZoomBlocks(uint16_t* buffer, int width, int height);

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
            if (value.length() >= 20 && (word(16) & 0x80000000u)) {  // 1.13 extended mask
                transitionMaskW2 = word(12);
                transitionMaskW3 = word(16);
            } else {
                transitionMaskW2 = 0xFFFFFFFFu;
                transitionMaskW3 = 0xFFFFFFFFu;
            }
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

// --------------------------------------------------
// Checker Cascade: 8 px checkerboard whose tiles ripple in diagonally (draws only the new image).
// --------------------------------------------------
void drawCheckerCascade(uint16_t* buffer, int width, int height) {
  const int cell = 8;
  const int nx = width / cell, ny = height / cell;
  const int steps = 30;
  for (int s = 0; s < steps; s++) {
    for (int ty = 0; ty < ny; ty++) {
      for (int tx = 0; tx < nx; tx++) {
        // Threshold 0..999: diagonal position (60%) plus checker parity (40%).
        int thr = ((tx + ty) * 600) / (nx + ny) + (((tx + ty) & 1) ? 400 : 0);
        int lo = (s * 1000) / steps, hi = ((s + 1) * 1000) / steps;
        if (thr >= lo && thr < hi) drawBlockRows(buffer, tx * cell, ty * cell, cell, width, height);
      }
    }
    delayMicroseconds(8000);
  }
}

// ==================================================
// FRAME-COMPOSED TRANSITIONS
// Each frame is built in composeBuffer from prevBuffer (old cover) and the new buffer, then
// pushed whole. Display is fixed at 240x240 (IMAGE_SIZE), so these use DISPLAY_* directly.
// ==================================================

static const int CW = DISPLAY_WIDTH, CH = DISPLAY_HEIGHT;

// Mirror a full frame in place: bit 0 = left/right, bit 1 = top/bottom.
static void mirrorFrame(uint16_t* b, uint8_t flip) {
  if (flip & 1)
    for (int y = 0; y < CH; y++) {
      uint16_t* r = b + y * CW;
      for (int a = 0, c = CW - 1; a < c; a++, c--) { uint16_t t = r[a]; r[a] = r[c]; r[c] = t; }
    }
  if (flip & 2) {
    static uint16_t tmp[DISPLAY_WIDTH];
    for (int a = 0, c = CH - 1; a < c; a++, c--) {
      memcpy(tmp, b + a * CW, CW * 2);
      memcpy(b + a * CW, b + c * CW, CW * 2);
      memcpy(b + c * CW, tmp, CW * 2);
    }
  }
}

// Mirrored transitions (1.13, 81-88) run an existing effect on mirrored covers; each composed frame is
// mirrored back just for the push, so the picture reads correctly and only the motion is reversed.
static uint8_t composeFlip = 0;

// Per-play speed (1.13): runTransition picks a random speed in 0.75x-1.3x so repeats don't look canned.
// Faster drops composed frames evenly; slower holds each frame a little longer. runTransition always
// draws the exact final cover afterwards, so a dropped last frame never matters.
static float transSpeed = 1.0f;
static float pushAcc = 0.0f;

static inline void pushComposedFrame() {
  if (transSpeed > 1.0f) {
    pushAcc += 1.0f / transSpeed;
    if (pushAcc < 1.0f) return;
    pushAcc -= 1.0f;
  }
  if (composeFlip) mirrorFrame(composeBuffer, composeFlip);
  gfx->draw16bitRGBBitmap(0, 0, composeBuffer, CW, CH);
  if (composeFlip) mirrorFrame(composeBuffer, composeFlip);  // effects may build on the last frame
  if (transSpeed < 1.0f) delayMicroseconds((uint32_t)((1.0f / transSpeed - 1.0f) * 13000.0f));
}

static inline float easeInOut(float t) {
  return t < 0.5f ? 2.0f * t * t : 1.0f - (-2.0f * t + 2.0f) * (-2.0f * t + 2.0f) / 2.0f;
}

static inline float clamp01(float v) { return v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v); }

// Blend two RGB565 pixels; k in 0..32 (0 = a, 32 = b). Spreads G apart from R/B so all three
// channels blend in one multiply.
static inline uint16_t blend565(uint16_t a, uint16_t b, uint32_t k) {
  uint32_t fa = (a | ((uint32_t)a << 16)) & 0x07E0F81F;
  uint32_t fb = (b | ((uint32_t)b << 16)) & 0x07E0F81F;
  uint32_t f = ((fa * (32 - k) + fb * k) >> 5) & 0x07E0F81F;
  return (uint16_t)(f | (f >> 16));
}

static inline uint8_t cellHash(uint32_t x, uint32_t y) {
  uint32_t h = x * 73856093u ^ y * 19349663u;
  h ^= h >> 13; h *= 0x5bd1e995u; h ^= h >> 15;
  return (uint8_t)h;
}

static const uint8_t BAYER8[8][8] = {
  { 0, 32,  8, 40,  2, 34, 10, 42}, {48, 16, 56, 24, 50, 18, 58, 26},
  {12, 44,  4, 36, 14, 46,  6, 38}, {60, 28, 52, 20, 62, 30, 54, 22},
  { 3, 35, 11, 43,  1, 33,  9, 41}, {51, 19, 59, 27, 49, 17, 57, 25},
  {15, 47,  7, 39, 13, 45,  5, 37}, {63, 31, 55, 23, 61, 29, 53, 21}};

// Card Stack: new cover slides in from the right over the old one, which stays put.
void drawCardStack(const uint16_t* oldB, const uint16_t* newB) {
  const int frames = 26;
  for (int f = 1; f <= frames; f++) {
    int x0 = (int)((1.0f - easeInOut((float)f / frames)) * CW);
    int w = CW - x0;
    for (int y = 0; y < CH; y++) {
      uint16_t* dst = composeBuffer + y * CW;
      memcpy(dst, oldB + y * CW, x0 * 2);
      memcpy(dst + x0, newB + y * CW, w * 2);
      if (x0 >= 3) for (int x = x0 - 3; x < x0; x++) dst[x] = blend565(dst[x], 0, 12);  // edge shadow
    }
    pushComposedFrame();
  }
}

// Static Dissolve (2 px random cells) and Dither Fade (8x8 Bayer): per-pixel threshold masks.
static void drawMaskDissolve(const uint16_t* oldB, const uint16_t* newB, bool bayer) {
  const int frames = 18;
  for (int f = 1; f <= frames; f++) {
    int level = (f * 256) / frames;  // pixels with threshold < level show the new image
    for (int y = 0; y < CH; y++) {
      const uint16_t* o = oldB + y * CW;
      const uint16_t* n = newB + y * CW;
      uint16_t* d = composeBuffer + y * CW;
      for (int x = 0; x < CW; x++) {
        int thr = bayer ? BAYER8[y & 7][x & 7] * 4 : cellHash(x >> 1, y >> 1);
        d[x] = thr < level ? n[x] : o[x];
      }
    }
    pushComposedFrame();
  }
}

// Push Left: both covers move together, carousel style.
void drawPushLeft(const uint16_t* oldB, const uint16_t* newB) {
  const int frames = 24;
  for (int f = 1; f <= frames; f++) {
    int o = (int)(easeInOut((float)f / frames) * CW);
    for (int y = 0; y < CH; y++) {
      uint16_t* d = composeBuffer + y * CW;
      memcpy(d, oldB + y * CW + o, (CW - o) * 2);
      memcpy(d + (CW - o), newB + y * CW, o * 2);
    }
    pushComposedFrame();
  }
}

// Crossfade: smooth per-pixel blend.
void drawCrossfade(const uint16_t* oldB, const uint16_t* newB) {
  const int frames = 16;
  for (int f = 1; f <= frames; f++) {
    uint32_t k = (uint32_t)(easeInOut((float)f / frames) * 32.0f + 0.5f);
    for (int i = 0; i < CW * CH; i++) composeBuffer[i] = blend565(oldB[i], newB[i], k);
    pushComposedFrame();
  }
}

// Squash a w-wide region of src columns [sx, sx+sw) into dst columns [dx, dx+w) on one row.
static inline void squashRow(uint16_t* dstRow, const uint16_t* srcRow, int sx, int sw, int dx, int w) {
  for (int x = 0; x < w; x++) dstRow[dx + x] = srcRow[sx + (x * sw) / w];
}

// Card Flip: whole cover narrows to a line and widens again showing the new art.
void drawCardFlip(const uint16_t* oldB, const uint16_t* newB) {
  const int frames = 24;
  for (int f = 1; f <= frames; f++) {
    float t = easeInOut((float)f / frames);
    int w = max(1, (int)(CW * fabsf(cosf(PI * t))));
    int x0 = (CW - w) / 2;
    const uint16_t* src = t < 0.5f ? oldB : newB;
    memset(composeBuffer, 0, IMAGE_SIZE);
    for (int y = 0; y < CH; y++) squashRow(composeBuffer + y * CW, src + y * CW, 0, CW, x0, w);
    pushComposedFrame();
  }
}

// Tile Flip Wave: 6x6 grid of 40 px tiles, each flipping with a diagonal delay.
void drawTileFlip(const uint16_t* oldB, const uint16_t* newB) {
  const int n = 6, ts = CW / n, frames = 30;
  for (int f = 1; f <= frames; f++) {
    float t = (float)f / frames;
    memset(composeBuffer, 0, IMAGE_SIZE);
    for (int ty = 0; ty < n; ty++) {
      for (int tx = 0; tx < n; tx++) {
        float lt = clamp01((t - (float)(tx + ty) / (2 * n - 2) * 0.55f) / 0.45f);
        int w = max(1, (int)(ts * fabsf(cosf(PI * lt))));
        const uint16_t* src = lt < 0.5f ? oldB : newB;
        int dx = tx * ts + (ts - w) / 2;
        if (w >= ts) {  // tile not flipping yet / already done: plain row copies, no per-pixel math
          for (int y = ty * ts; y < (ty + 1) * ts; y++)
            memcpy(composeBuffer + y * CW + tx * ts, src + y * CW + tx * ts, ts * 2);
          continue;
        }
        for (int y = ty * ts; y < (ty + 1) * ts; y++)
          squashRow(composeBuffer + y * CW, src + y * CW, tx * ts, ts, dx, w);
      }
    }
    pushComposedFrame();
  }
}

// Block Drop: 40 px blocks fall into place over the old cover, bottom row first.
void drawBlockDrop(const uint16_t* oldB, const uint16_t* newB) {
  const int n = 6, bs = CW / n, frames = 36;
  for (int f = 1; f <= frames; f++) {
    float t = (float)f / frames;
    memcpy(composeBuffer, oldB, IMAGE_SIZE);
    for (int row = n - 1; row >= 0; row--) {
      for (int bx = 0; bx < n; bx++) {
        int order = (n - 1 - row) * n + (cellHash(bx, row) % n);
        float lt = clamp01((t - (float)order / (n * n) * 0.75f) / 0.25f);
        if (lt <= 0.0f) continue;
        int target = row * bs;
        int y = min(target, (int)(-bs + (target + bs) * lt * lt));
        for (int r = 0; r < bs; r++) {
          int dy = y + r;
          if (dy < 0 || dy >= CH) continue;
          memcpy(composeBuffer + dy * CW + bx * bs, newB + (target + r) * CW + bx * bs, bs * 2);
        }
      }
    }
    pushComposedFrame();
  }
}

// Melt: old cover drips down in 4 px columns, revealing the new one underneath.
void drawMelt(const uint16_t* oldB, const uint16_t* newB) {
  const int col = 4, frames = 30;
  for (int f = 1; f <= frames; f++) {
    float t = (float)f / frames;
    memcpy(composeBuffer, newB, IMAGE_SIZE);
    for (int x = 0; x < CW; x += col) {
      float start = (cellHash(x, 7) / 255.0f) * 0.3f;
      float lt = clamp01((t - start) / 0.7f);
      int dy = (int)(lt * lt * CH);
      for (int y = dy; y < CH; y++)
        memcpy(composeBuffer + y * CW + x, oldB + (y - dy) * CW + x, col * 2);
    }
    pushComposedFrame();
  }
}

// Zoom Punch: new cover grows from the center over the old one with a small overshoot.
void drawZoomPunch(const uint16_t* oldB, const uint16_t* newB) {
  const int frames = 26;
  static int16_t srcX[DISPLAY_WIDTH];
  for (int f = 1; f <= frames; f++) {
    float u = (float)f / frames - 1.0f;
    float e = 1.0f + 2.70158f * u * u * u + 1.70158f * u * u;  // easeOutBack
    int s = max(2, (int)(e * CW));
    int x0 = (CW - s) / 2, y0 = (CH - s) / 2;
    memcpy(composeBuffer, oldB, IMAGE_SIZE);
    int xa = max(0, x0), xb = min(CW, x0 + s);
    for (int x = xa; x < xb; x++) srcX[x] = (int16_t)(((x - x0) * CW) / s);
    for (int y = max(0, y0); y < min(CH, y0 + s); y++) {
      const uint16_t* srow = newB + (((y - y0) * CH) / s) * CW;
      uint16_t* d = composeBuffer + y * CW;
      for (int x = xa; x < xb; x++) d[x] = srow[srcX[x]];
    }
    pushComposedFrame();
  }
  gfx->draw16bitRGBBitmap(0, 0, (uint16_t*)newB, CW, CH);  // land exactly on the final frame
}

// ==================================================
// TRANSITIONS, SET 3 (indices 28-39). Same compose pattern as above.
// ==================================================

static inline uint16_t shade565(uint16_t c, float f) {
  int k = (int)(f * 256.0f);
  if (k < 0) k = 0;
  int r = (((c >> 11) & 31) * k) >> 8, g = (((c >> 5) & 63) * k) >> 8, b = ((c & 31) * k) >> 8;
  if (r > 31) r = 31;
  if (g > 63) g = 63;
  if (b > 31) b = 31;
  return (uint16_t)((r << 11) | (g << 5) | b);
}

static inline float luma565(uint16_t c) {
  return (((c >> 11) & 31) / 31.0f) * 0.30f + (((c >> 5) & 63) / 63.0f) * 0.59f + ((c & 31) / 31.0f) * 0.11f;
}

static inline int clampPx(int v) { return v < 0 ? 0 : (v > 239 ? 239 : v); }

// Nearest-neighbor scale of a full 240x240 src into the rect (dx, dy, dw, dh) of composeBuffer.
static void blitScaled(const uint16_t* src, float dx, float dy, float dw, float dh) {
  static int16_t sxTab[DISPLAY_WIDTH];
  if (dw < 1.0f || dh < 1.0f) return;
  int x0 = max(0, (int)ceilf(dx)), x1 = min(CW, (int)ceilf(dx + dw));
  int y0 = max(0, (int)ceilf(dy)), y1 = min(CH, (int)ceilf(dy + dh));
  for (int x = x0; x < x1; x++) sxTab[x] = (int16_t)clampPx((int)((x - dx) * CW / dw));
  for (int y = y0; y < y1; y++) {
    const uint16_t* srow = src + clampPx((int)((y - dy) * CH / dh)) * CW;
    uint16_t* d = composeBuffer + y * CW;
    for (int x = x0; x < x1; x++) d[x] = srow[sxTab[x]];
  }
}

// Corner Peel: old cover peels from the bottom-right corner; pale paper back, shadow on the crease.
void drawCornerPeel(const uint16_t* oldB, const uint16_t* newB) {
  const int frames = 28;
  for (int f = 1; f <= frames; f++) {
    // Fold position in q = x + y units (0..478).
    int Fq = (int)((359.4f * (1.0f - easeInOut((float)f / frames)) - 10.0f) * 1.41421f);
    for (int y = 0; y < CH; y++) {
      uint16_t* d = composeBuffer + y * CW;
      for (int x = 0; x < CW; x++) {
        int q = x + y, i = y * CW + x;
        if (q > Fq) {
          uint16_t c = newB[i];
          if (q < Fq + 22) c = shade565(c, 0.5f + 0.5f * (q - Fq) / 22.0f);
          d[x] = c;
        } else {
          int k = Fq - q, sx = x + k, sy = y + k;  // reflection across the fold line
          if (sx < CW && sy < CH) {
            uint16_t c = blend565(oldB[sy * CW + sx], 0xFFFF, 18);
            if (k < 8) c = shade565(c, 0.75f + k / 32.0f);
            d[x] = c;
          } else {
            d[x] = oldB[i];
          }
        }
      }
    }
    pushComposedFrame();
  }
}

// Shatter: the old cover breaks into 72 glass shards that crack, then tumble off the screen.
struct Shard { float ax, ay, bx, by, cx2, cy2; float cx, cy, delay, dx, rot, area; };
static Shard shards[72];
static bool shardsReady = false;

static void initShards() {
  float vx[7][7], vy[7][7];
  for (int j = 0; j <= 6; j++)
    for (int i = 0; i <= 6; i++) {
      bool edge = i == 0 || j == 0 || i == 6 || j == 6;
      vx[j][i] = i * 40 + (edge ? 0 : (cellHash(j * 31 + i, 1) / 255.0f - 0.5f) * 22.0f);
      vy[j][i] = j * 40 + (edge ? 0 : (cellHash(j * 17 + i, 2) / 255.0f - 0.5f) * 22.0f);
    }
  int k = 0;
  for (int j = 0; j < 6; j++)
    for (int i = 0; i < 6; i++)
      for (int h = 0; h < 2; h++) {
        Shard& s = shards[k];
        s.ax = vx[j][i]; s.ay = vy[j][i];
        if (h == 0) { s.bx = vx[j][i + 1]; s.by = vy[j][i + 1]; s.cx2 = vx[j + 1][i + 1]; s.cy2 = vy[j + 1][i + 1]; }
        else        { s.bx = vx[j + 1][i + 1]; s.by = vy[j + 1][i + 1]; s.cx2 = vx[j + 1][i]; s.cy2 = vy[j + 1][i]; }
        s.cx = (s.ax + s.bx + s.cx2) / 3.0f; s.cy = (s.ay + s.by + s.cy2) / 3.0f;
        s.delay = hypotf(s.cx - 120, s.cy - 120) / 170.0f * 0.4f + cellHash(k, 77) / 255.0f * 0.12f;
        s.dx = (cellHash(k, 3) / 255.0f - 0.5f) * 90.0f;
        s.rot = (cellHash(k, 9) / 255.0f - 0.5f) * 3.0f;
        s.area = (s.bx - s.ax) * (s.cy2 - s.ay) - (s.by - s.ay) * (s.cx2 - s.ax);
        k++;
      }
  shardsReady = true;
}

void drawShatter(const uint16_t* oldB, const uint16_t* newB) {
  if (!shardsReady) initShards();
  const int frames = 32;
  for (int f = 1; f <= frames; f++) {
    float t = (float)f / frames;
    memcpy(composeBuffer, newB, IMAGE_SIZE);
    for (int k = 0; k < 72; k++) {
      const Shard& s = shards[k];
      float lt = clamp01((t - s.delay) / 0.5f);
      float ox = s.dx * lt, oy = lt * lt * 330.0f, th = s.rot * lt;
      float cs = cosf(th), sn = sinf(th);
      bool cracks = t > s.delay - 0.18f;
      // Bounding box of the moved shard (corners rotated around its centroid, then offset).
      float px[3] = {s.ax, s.bx, s.cx2}, py[3] = {s.ay, s.by, s.cy2};
      float minX = 1e9f, maxX = -1e9f, minY = 1e9f, maxY = -1e9f;
      for (int v = 0; v < 3; v++) {
        float rx = s.cx + cs * (px[v] - s.cx) - sn * (py[v] - s.cy) + ox;
        float ry = s.cy + sn * (px[v] - s.cx) + cs * (py[v] - s.cy) + oy;
        minX = fminf(minX, rx); maxX = fmaxf(maxX, rx); minY = fminf(minY, ry); maxY = fmaxf(maxY, ry);
      }
      int x0 = max(0, (int)minX), x1 = min(CW - 1, (int)maxX + 1);
      int y0 = max(0, (int)minY), y1 = min(CH - 1, (int)maxY + 1);
      if (x0 > x1 || y0 > y1) continue;
      for (int y = y0; y <= y1; y++) {
        for (int x = x0; x <= x1; x++) {
          // Map the screen pixel back into the unmoved shard.
          float rx = x + 0.5f - s.cx - ox, ry = y + 0.5f - s.cy - oy;
          float sx = s.cx + cs * rx + sn * ry, sy = s.cy - sn * rx + cs * ry;
          float w0 = ((s.bx - s.ax) * (sy - s.ay) - (s.by - s.ay) * (sx - s.ax)) / s.area;
          float w1 = ((s.cx2 - s.bx) * (sy - s.by) - (s.cy2 - s.by) * (sx - s.bx)) / s.area;
          float w2 = 1.0f - w0 - w1;
          if (w0 < 0 || w1 < 0 || w2 < 0) continue;
          uint16_t c = oldB[clampPx((int)sy) * CW + clampPx((int)sx)];
          if (cracks && fminf(w0, fminf(w1, w2)) < 0.035f) c = blend565(c, 0xFFFF, lt > 0 ? 14 : 24);
          composeBuffer[y * CW + x] = c;
        }
      }
    }
    pushComposedFrame();
  }
}

// Cube Turn: both covers on the faces of a cube turning 90 degrees, with perspective and shading.
void drawCubeTurn(const uint16_t* oldB, const uint16_t* newB) {
  const int frames = 26;
  for (int f = 1; f <= frames; f++) {
    float th = easeInOut((float)f / frames) * (PI / 2), sn = sinf(th), cs = cosf(th);
    float wa = CW * cs;
    // Only the black margins above and below the squashed faces need clearing: every column rewrites
    // rows y0..y1, and h >= 1 - 0.18 * max(sn, cs), so rows in [band, CH - band) are always overwritten.
    int band = min(CH / 2, (int)ceilf(120.0f * 0.18f * fmaxf(sn, cs)) + 1);
    memset(composeBuffer, 0, band * CW * 2);
    memset(composeBuffer + (CH - band) * CW, 0, band * CW * 2);
    for (int x = 0; x < CW; x++) {
      const uint16_t* D; float u, h, sh;
      if (x < wa) { D = oldB; u = x / wa; h = 1.0f - 0.18f * sn * (1.0f - u); sh = 1.0f - 0.55f * sn; }
      else { D = newB; u = (x - wa) / fmaxf(1.0f, CW - wa); h = 1.0f - 0.18f * cs * u; sh = 1.0f - 0.55f * cs; }
      int sx = clampPx((int)(u * CW));
      // Per column: the visible rows are a single range, source rows step by a constant (16.16 fixed
      // point) and the shade factor is constant, so the inner loop has no float math, no divide and no
      // per-pixel range test (it used to have all three, for each of 57,600 pixels per frame).
      int y0 = max(0, (int)ceilf(120.0f - 120.0f * h)), y1 = min(CH, (int)ceilf(120.0f + 120.0f * h));
      if (y1 <= y0) continue;
      float inv = 1.0f / h;
      int32_t step = (int32_t)(inv * 65536.0f);
      int32_t pos = (int32_t)(((y0 - 120) * inv + 120.0f) * 65536.0f);
      int k = (int)(sh * 256.0f);
      if (k < 0) k = 0;
      const uint16_t* col = D + sx;
      uint16_t* out = composeBuffer + y0 * CW + x;
      for (int y = y0; y < y1; y++, pos += step, out += CW) {
        int syi = pos >> 16;
        if (syi < 0) syi = 0; else if (syi > CH - 1) syi = CH - 1;
        uint16_t c = col[syi * CW];
        int r = (((c >> 11) & 31) * k) >> 8, g = (((c >> 5) & 63) * k) >> 8, b = ((c & 31) * k) >> 8;
        if (r > 31) r = 31;
        if (g > 63) g = 63;
        if (b > 31) b = 31;
        *out = (uint16_t)((r << 11) | (g << 5) | b);
      }
    }
    pushComposedFrame();
  }
}

// Cube Up (1.13): Cube Turn on the horizontal axis; the old face rolls away upward. Cube Down mirrors it.
void drawCubeTurnV(const uint16_t* oldB, const uint16_t* newB) {
  const int frames = 26;
  for (int f = 1; f <= frames; f++) {
    float th = easeInOut((float)f / frames) * (PI / 2), sn = sinf(th), cs = cosf(th), wa = CH * cs;
    memset(composeBuffer, 0, IMAGE_SIZE);
    for (int y = 0; y < CH; y++) {
      const uint16_t* D; float u, h, sh;
      if (y < wa) { D = oldB; u = y / wa; h = 1.0f - 0.18f * sn * (1.0f - u); sh = 1.0f - 0.55f * sn; }
      else { D = newB; u = (y - wa) / fmaxf(1.0f, CH - wa); h = 1.0f - 0.18f * cs * u; sh = 1.0f - 0.55f * cs; }
      const uint16_t* row = D + clampPx((int)(u * CH)) * CW;
      int x0 = max(0, (int)ceilf(120.0f - 120.0f * h)), x1 = min(CW, (int)ceilf(120.0f + 120.0f * h));
      uint16_t* d = composeBuffer + y * CW;
      for (int x = x0; x < x1; x++) d[x] = shade565(row[clampPx((int)((x - 120) / h + 120))], sh);
    }
    pushComposedFrame();
  }
}

// Jelly Drop: new cover falls in, squashes on impact and wobbles until it settles.
void drawJellyDrop(const uint16_t* oldB, const uint16_t* newB) {
  const int frames = 34;
  for (int f = 1; f <= frames; f++) {
    float t = (float)f / frames;
    memcpy(composeBuffer, oldB, IMAGE_SIZE);
    if (t < 0.4f) {
      float a = t / 0.4f;
      blitScaled(newB, 0, -CH * (1.0f - a * a), CW, CH);
    } else {
      float u = (t - 0.4f) / 0.6f, s = 1.0f - 0.28f * expf(-4.0f * u) * cosf(u * 20.0f), w = CW / s;
      blitScaled(newB, (CW - w) / 2, CH - CH * s, w, CH * s);
    }
    pushComposedFrame();
  }
}

// Tile Spin: 36 tiles each spin half a turn and shrink as they go, spiraling out from the center.
void drawTileSpin(const uint16_t* oldB, const uint16_t* newB) {
  static int8_t order[36];
  static bool orderReady = false;
  if (!orderReady) {
    float key[36];
    for (int i = 0; i < 36; i++) {
      float x = i % 6 - 2.5f, y = i / 6 - 2.5f;
      key[i] = fmaxf(fabsf(x), fabsf(y)) + atan2f(y, x) / (2 * PI);
      order[i] = i;
    }
    for (int i = 1; i < 36; i++)
      for (int j = i; j > 0 && key[order[j]] < key[order[j - 1]]; j--) {
        int8_t tmp = order[j]; order[j] = order[j - 1]; order[j - 1] = tmp;
      }
    orderReady = true;
  }
  const int frames = 32;
  for (int f = 1; f <= frames; f++) {
    float t = (float)f / frames;
    memset(composeBuffer, 0, IMAGE_SIZE);
    for (int r = 0; r < 36; r++) {
      int tile = order[r], tx = tile % 6, ty = tile / 6;
      float lt = clamp01((t - r / 36.0f * 0.6f) / 0.4f), e = easeInOut(lt);
      bool firstHalf = lt < 0.5f;
      float a = firstHalf ? e * PI : (e - 1.0f) * PI, sc = 1.0f - 0.4f * sinf(PI * lt);
      const uint16_t* src = firstHalf ? oldB : newB;
      float ccx = tx * 40 + 20, ccy = ty * 40 + 20, cs = cosf(a), sn = sinf(a), ext = 20 * sc * 1.4143f;
      int x0 = max(0, (int)(ccx - ext)), x1 = min(CW - 1, (int)(ccx + ext));
      int y0 = max(0, (int)(ccy - ext)), y1 = min(CH - 1, (int)(ccy + ext));
      for (int y = y0; y <= y1; y++)
        for (int x = x0; x <= x1; x++) {
          float dx = x + 0.5f - ccx, dy = y + 0.5f - ccy;
          float lx = (cs * dx + sn * dy) / sc, ly = (-sn * dx + cs * dy) / sc;
          if (lx < -20 || lx >= 20 || ly < -20 || ly >= 20) continue;
          composeBuffer[y * CW + x] = src[(int)(ccy + ly) * CW + (int)(ccx + lx)];
        }
    }
    pushComposedFrame();
  }
}

// Infinite Zoom: new cover appears as a small framed picture inside the old one; the camera dives in.
void drawInfiniteZoom(const uint16_t* oldB, const uint16_t* newB) {
  const int frames = 30;
  for (int f = 1; f <= frames; f++) {
    float z = easeInOut((float)f / frames), k = powf(6.0f, z), sa = CW * k, sb = 40.0f * k;
    blitScaled(oldB, 120 - sa / 2, 120 - sa / 2, sa, sa);
    if (z < 0.97f) {  // white picture frame, 2 px
      int f0 = max(0, (int)(120 - sb / 2 - 2)), f1 = min(CW, (int)(120 + sb / 2 + 2));
      for (int y = f0; y < f1; y++)
        for (int x = f0; x < f1; x++) composeBuffer[y * CW + x] = 0xFFFF;
    }
    blitScaled(newB, 120 - sb / 2, 120 - sb / 2, sb, sb);
    pushComposedFrame();
  }
}

// RGB Split: red, green and blue channels fly apart, then snap together on the new cover.
void drawRgbSplit(const uint16_t* oldB, const uint16_t* newB) {
  const int frames = 22;
  for (int f = 1; f <= frames; f++) {
    float t = (float)f / frames;
    int off = (int)(sinf(PI * t) * 22.0f);
    const uint16_t* D = t < 0.5f ? oldB : newB;
    for (int y = 0; y < CH; y++) {
      const uint16_t* row = D + y * CW;
      const uint16_t* grow = D + clampPx(y + off / 2) * CW;
      uint16_t* d = composeBuffer + y * CW;
      for (int x = 0; x < CW; x++)
        d[x] = (row[clampPx(x - off)] & 0xF800) | (grow[x] & 0x07E0) | (row[clampPx(x + off)] & 0x001F);
    }
    pushComposedFrame();
  }
}

// Accordion: old cover folds into 8 shaded pleats that squeeze into the right edge.
void drawAccordion(const uint16_t* oldB, const uint16_t* newB) {
  const int frames = 24, n = 8, pw = CW / n;
  for (int f = 1; f <= frames; f++) {
    float e = easeInOut((float)f / frames), w = pw * (1.0f - e);
    memcpy(composeBuffer, newB, IMAGE_SIZE);
    if (w >= 0.5f) {
      for (int i = 0; i < n; i++) {
        int dx0 = (int)roundf(CW - (n - i) * w), dx1 = (int)roundf(CW - (n - i - 1) * w), dw = dx1 - dx0;
        if (dw <= 0) continue;
        float sh = 1.0f - ((i & 1) ? 0.45f : 0.08f) * e;
        for (int y = 0; y < CH; y++) {
          const uint16_t* srow = oldB + y * CW + i * pw;
          uint16_t* d = composeBuffer + y * CW;
          for (int x = 0; x < dw; x++) d[dx0 + x] = shade565(srow[(x * pw) / dw], sh);
        }
      }
    }
    pushComposedFrame();
  }
}

// Ink Bleed: six ink blots soak outward with ragged edges until they merge.
static uint8_t* inkMask = nullptr;

static bool initInkMask() {
  if (inkMask) return true;
  inkMask = (uint8_t*)ps_malloc(CW * CH);
  if (!inkMask) return false;
  float sx[6], sy[6], sr[6];
  for (int i = 0; i < 6; i++) {
    sx[i] = 30 + cellHash(i * 11 + 1, 4) / 255.0f * 180;
    sy[i] = 30 + cellHash(i * 13 + 2, 5) / 255.0f * 180;
    sr[i] = 0.7f + cellHash(i * 5 + 9, 6) / 255.0f * 0.6f;
  }
  static float tmp[DISPLAY_WIDTH];
  float mx = 1.0f;
  // Two passes: find the max, then quantize to 0..250.
  for (int pass = 0; pass < 2; pass++)
    for (int y = 0; y < CH; y++) {
      for (int x = 0; x < CW; x++) {
        float d = 1e9f;
        for (int i = 0; i < 6; i++) d = fminf(d, hypotf(x - sx[i], y - sy[i]) / sr[i]);
        d += (sinf(x * 0.11f + y * 0.07f) + sinf(x * 0.23f - y * 0.19f) + sinf((x + y) * 0.31f)) * 7.0f
             + cellHash(x, y) / 255.0f * 6.0f;
        tmp[x] = d;
        if (pass == 0 && d > mx) mx = d;
      }
      if (pass == 1)
        for (int x = 0; x < CW; x++) inkMask[y * CW + x] = (uint8_t)(fmaxf(0, tmp[x]) / mx * 250.0f);
    }
  return true;
}

void drawInkBleed(const uint16_t* oldB, const uint16_t* newB) {
  if (!initInkMask()) { drawCrossfade(oldB, newB); return; }
  const int frames = 28;
  for (int f = 1; f <= frames; f++) {
    int lv = (int)(easeInOut((float)f / frames) * 262.0f);
    for (int i = 0; i < CW * CH; i++) {
      int v = inkMask[i];
      composeBuffer[i] = v < lv ? (v > lv - 7 ? 0 : newB[i]) : oldB[i];
    }
    pushComposedFrame();
  }
}

// Crack Split: a jagged crack runs down the cover, then the halves slide apart.
void drawCrackSplit(const uint16_t* oldB, const uint16_t* newB) {
  static int16_t crack[DISPLAY_HEIGHT];
  int cx = 120;
  for (int y = 0; y < CH; y++) {  // a new random crack every time
    cx += random(-4, 5);
    cx = max(70, min(170, cx));
    crack[y] = cx;
  }
  const int crackFrames = 10, splitFrames = 22;
  for (int f = 1; f <= crackFrames; f++) {
    int ly = (f * CH) / crackFrames;
    memcpy(composeBuffer, oldB, IMAGE_SIZE);
    for (int y = 0; y < ly; y++)
      for (int x = crack[y] - 1; x <= crack[y] + 1; x++) composeBuffer[y * CW + x] = 0xFFFF;
    pushComposedFrame();
  }
  for (int f = 1; f <= splitFrames; f++) {
    int off = (int)(easeInOut((float)f / splitFrames) * 135.0f);
    for (int y = 0; y < CH; y++) {
      uint16_t* d = composeBuffer + y * CW;
      for (int x = 0; x < CW; x++) {
        int l = x + off, r = x - off;
        d[x] = l < crack[y] ? oldB[y * CW + l] : (r >= crack[y] && r < CW) ? oldB[y * CW + r] : newB[y * CW + x];
      }
    }
    pushComposedFrame();
  }
}

// Sand Pile: the new cover pours down as grains and piles up from the bottom row.
void drawSandPile(const uint16_t* oldB, const uint16_t* newB) {
  const int frames = 36;
  for (int f = 1; f <= frames; f++) {
    float t = (float)f / frames;
    memcpy(composeBuffer, oldB, IMAGE_SIZE);
    for (int y = CH - 1; y >= 0; y--) {
      float rowLand = (CH - 1 - y) / (float)CH * 0.72f + 0.06f;
      // Whole-row shortcuts (the per-pixel loop below is the slow part: hash + float math x 57,600):
      // every grain in this row has landed -> copy the row; none has started falling -> skip it.
      // Grain landing times span rowLand .. rowLand + 0.08 (hash/255 * 0.08), start = landing - 0.2.
      if (t >= rowLand + 0.08f) {
        memcpy(composeBuffer + y * CW, newB + y * CW, CW * 2);
        continue;
      }
      if (t < rowLand - 0.2f) continue;
      for (int x = 0; x < CW; x++) {
        float tl = rowLand + cellHash(x, y) / 255.0f * 0.08f, ts = tl - 0.2f;
        if (t < ts) continue;
        int i = y * CW + x;
        if (t >= tl) { composeBuffer[i] = newB[i]; continue; }
        float u = (t - ts) / 0.2f;
        int py = (int)(-8 + (y + 8) * u * u);
        if (py >= 0) composeBuffer[py * CW + x] = newB[i];
      }
    }
    pushComposedFrame();
  }
}

// Halftone: old cover breaks into newsprint dots that shrink away; new cover dots grow back.
void drawHalftone(const uint16_t* oldB, const uint16_t* newB) {
  static float lumOld[900], lumNew[900];
  for (int c = 0; c < 900; c++) {
    int cx = (c % 30) * 8, cy = (c / 30) * 8;
    float so = 0, sn = 0;
    for (int y = 0; y < 8; y++)
      for (int x = 0; x < 8; x++) {
        so += luma565(oldB[(cy + y) * CW + cx + x]);
        sn += luma565(newB[(cy + y) * CW + cx + x]);
      }
    lumOld[c] = so / 64; lumNew[c] = sn / 64;
  }
  const int frames = 28;
  for (int f = 1; f <= frames; f++) {
    float t = (float)f / frames;
    bool firstHalf = t < 0.5f;
    float k = firstHalf ? t * 2 : (1 - t) * 2;
    const uint16_t* D = firstHalf ? oldB : newB;
    const float* L = firstHalf ? lumOld : lumNew;
    for (int y = 0; y < CH; y++)
      for (int x = 0; x < CW; x++) {
        int c = (y >> 3) * 30 + (x >> 3);
        float dx = (x & 7) - 3.5f, dy = (y & 7) - 3.5f, R = (1 - k) * 7.5f * (0.35f + 0.65f * L[c]);
        composeBuffer[y * CW + x] = dx * dx + dy * dy < R * R ? D[y * CW + x] : 0;
      }
    pushComposedFrame();
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
// ==================================================
// QUICK TRANSITIONS (indices 40-51): one threshold byte per pixel, revealed over QUICK_FRAMES frames.
// Each map is built once on first use (57.6 KB PSRAM each). Per frame it is one compare per pixel
// plus the full-frame push, so each runs in roughly QUICK_FRAMES x ~13 ms.
// ==================================================

#define QUICK_FRAMES 10
#define QUICK_MAP_COUNT 20
static uint8_t* quickMaps[QUICK_MAP_COUNT] = {nullptr};

static float quickThreshold(int id, int x, int y) {
  float dx = x + 0.5f - 120, dy = y + 0.5f - 120, r = sqrtf(dx * dx + dy * dy);
  float ang = atan2f(dx, -dy); if (ang < 0) ang += 2 * PI;  // 0 at 12 o'clock, clockwise
  switch (id) {
    case 0: return r;                                            // Quick Iris
    case 1: return fabsf(dx) + fabsf(dy);                        // Diamond Iris
    case 2: {                                                    // Heart Iris
      float u = dx / 120 * 1.25f, v = -dy / 120 * 1.25f + 0.15f, lo = 0, hi = 3;
      for (int i = 0; i < 16; i++) {
        float s = (lo + hi) / 2, a = u / s, b = v / s, q = a * a + b * b - 1;
        if (q * q * q - a * a * b * b * b <= 0) hi = s; else lo = s;
      }
      return hi;
    }
    case 3: return ang;                                          // Clock Sweep
    case 4: return (120 - fabsf(dx)) + fabsf(dy) * 0.6f;         // Bow Tie
    case 5: return (CW - x) * 0.6f + cellHash(y >> 1, 11) * 0.4f; // Wind (rows blow in from the right)
    case 6: {                                                    // Polka Dots, left to right
      float cx = (x / 24) * 24 + 12, cy = (y / 24) * 24 + 12;
      return x * 0.5f + hypotf(x + 0.5f - cx, y + 0.5f - cy) * 6.0f;
    }
    case 7: return y * 0.55f + cellHash(x >> 3, 12) * 0.52f;     // Rain Columns
    case 8: return x * 0.8f + 48 * (0.5f + 0.5f * sinf(y / 240.0f * 4 * PI));  // Wave Wipe
    case 9: return (y % 20) * 9.0f + (y / 20) * 5.0f;            // Venetian H
    case 10: {                                                   // Spiral In (8 px rings)
      int ring = min(min(x, y), min(CW - 1 - x, CH - 1 - y)) / 8;
      return ring + ang / (2 * PI);
    }
    // 1.13 base maps, used only through the VARIANTS table (flips / inverses / neon edges).
    case 12: return y;                                           // Linear, top first
    case 13: return fmaxf(fabsf(dx), fabsf(dy));                 // Box from the centre
    case 14: return fabsf(dy);                                   // Split from the middle row
    case 15: return fminf(fabsf(dx), fabsf(dy));                 // Plus
    case 16: return fmodf(ang, PI / 2);                          // Wheel, 4 spokes
    case 17: return cellHash(y >> 2, 21);                        // Random Bars, 4 px rows
    case 18: {                                                   // Halftone, 20 px dots
      float fx = (x % 20) - 9.5f, fy = (y % 20) - 9.5f;
      return sqrtf(fx * fx + fy * fy);
    }
    case 19: return x + y;                                       // Diagonal, top-left first
    default: return 0;                                           // 11 = Luma Wipe (per image)
  }
}

static uint8_t* getQuickMap(int id) {
  if (quickMaps[id]) return quickMaps[id];
  uint8_t* m = (uint8_t*)ps_malloc(CW * CH);
  if (!m) return nullptr;
  float mn = 1e9f, mx = -1e9f;  // two passes: range, then quantize to 0..250
  for (int y = 0; y < CH; y++)
    for (int x = 0; x < CW; x++) {
      float v = quickThreshold(id, x, y);
      if (v < mn) mn = v;
      if (v > mx) mx = v;
    }
  float span = (mx - mn) > 0 ? (mx - mn) : 1;
  for (int y = 0; y < CH; y++)
    for (int x = 0; x < CW; x++)
      m[y * CW + x] = (uint8_t)((quickThreshold(id, x, y) - mn) / span * 250.0f);
  quickMaps[id] = m;
  return m;
}

// Variant flags for a threshold map: read it reversed (INV), mirrored, or transposed; GLOW paints a
// coloured leading edge on the reveal front.
#define QV_INV  1
#define QV_MX   2
#define QV_MY   4
#define QV_TR   8
#define QV_GLOW 16
#define QV_GLOW_BAND 24  // edge width in threshold units (map runs 0..250)

static const uint8_t* lumaMapFor(const uint16_t* newB) {
  static uint8_t* lumaMap = nullptr;
  if (!lumaMap) lumaMap = (uint8_t*)ps_malloc(CW * CH);
  if (!lumaMap) return nullptr;
  for (int i = 0; i < CW * CH; i++) lumaMap[i] = (uint8_t)(luma565(newB[i]) * 250.0f);
  return lumaMap;
}

void drawQuickMaskEx(int id, uint8_t flags, uint16_t tint, const uint16_t* oldB, const uint16_t* newB) {
  // 11 = Luma Wipe: dark parts of the new cover arrive first, highlights last.
  const uint8_t* m = (id == 11) ? lumaMapFor(newB) : getQuickMap(id);
  if (!m) { drawPushLeft(oldB, newB); return; }
  const bool glow = flags & QV_GLOW, plain = (flags & (QV_MX | QV_MY | QV_TR)) == 0;
  const int top = glow ? 256 + QV_GLOW_BAND : 256;  // glow needs extra travel so the edge leaves the frame
  for (int f = 1; f <= QUICK_FRAMES; f++) {
    int level = (f * top) / QUICK_FRAMES;
    for (int y = 0; y < CH; y++) {
      int sy = (flags & QV_MY) ? CH - 1 - y : y;
      uint16_t* d = composeBuffer + y * CW;
      const uint16_t* o = oldB + y * CW;
      const uint16_t* n = newB + y * CW;
      for (int x = 0; x < CW; x++) {
        int v;
        if (plain) v = m[y * CW + x];
        else {
          int sx = (flags & QV_MX) ? CW - 1 - x : x;
          v = (flags & QV_TR) ? m[sx * CW + sy] : m[sy * CW + sx];
        }
        if (flags & QV_INV) v = 250 - v;
        if (v >= level) { d[x] = o[x]; continue; }
        int lag = level - v;
        d[x] = (glow && lag < QV_GLOW_BAND) ? blend565(n[x], tint, 32 - (lag * 32) / QV_GLOW_BAND) : n[x];
      }
    }
    pushComposedFrame();
  }
}

void drawQuickMask(int id, const uint16_t* oldB, const uint16_t* newB) {
  drawQuickMaskEx(id, 0, 0, oldB, newB);
}

// Indices 52-80, in order. Each is an existing or new threshold map read a different way.
struct QuickVariant { uint8_t map, flags; uint16_t tint; const char* name; };
static const QuickVariant VARIANTS[] = {
  {12, 0, 0, "Wipe Down"},
  {0, QV_INV, 0, "Iris Close"},
  {1, QV_INV, 0, "Diamond Close"},
  {2, QV_INV, 0, "Heart Close"},
  {3, QV_MX, 0, "Clock Reverse"},
  {4, QV_INV, 0, "Bow Tie Close"},
  {5, QV_MX, 0, "Wind Reverse"},
  {6, QV_MX, 0, "Polka Dots Reverse"},
  {7, QV_MY, 0, "Rain Rise"},
  {8, QV_MX, 0, "Wave Wipe Reverse"},
  {10, QV_INV, 0, "Spiral Out"},
  {13, QV_INV, 0, "Box Close"},
  {14, QV_INV, 0, "Split Close H"},
  {14, QV_TR | QV_INV, 0, "Split Close V"},
  {19, QV_MY, 0, "Diagonal Up"},
  {19, QV_MX, 0, "Diagonal Down Left"},
  {18, QV_INV, 0, "Halftone Shrink"},
  {11, QV_INV, 0, "Luma Wipe Reverse"},
  {15, 0, 0, "Plus Wipe"},
  {15, QV_INV, 0, "Plus Close"},
  {16, 0, 0, "Wheel"},
  {17, 0, 0, "Random Bars"},
  {17, QV_TR, 0, "Random Bars V"},
  // Neon edges: 2000s-UI colours on the reveal front.
  {0, QV_GLOW, 0x07FF, "Neon Iris"},        // electric cyan
  {3, QV_GLOW, 0x07E0, "Radar Sweep"},      // phosphor green
  {12, QV_TR | QV_GLOW, 0xF81F, "Laser Wipe"},  // magenta, left to right
  {10, QV_GLOW, 0x067F, "Aqua Spiral"},     // Aqua blue
  {1, QV_GLOW, 0xF81F, "Plasma Diamond"},   // magenta
  {13, QV_GLOW, 0xFC60, "Orange Box"},      // iPod orange
};
static_assert(sizeof(VARIANTS) / sizeof(VARIANTS[0]) == TRANSITION_VARIANT_LAST - TRANSITION_VARIANT_FIRST + 1,
              "VARIANTS must cover indices 52-80 exactly");

// ==================================================
// 1.13 ZOOM-OUTS AND 2000s-TECH EFFECTS (indices 89-96). Same compose pattern.
// ==================================================

// Zoom Out: the old cover pulls back a touch, then shrinks into the centre with a drop shadow.
void drawZoomOut(const uint16_t* oldB, const uint16_t* newB) {
  const int frames = 24;
  for (int f = 1; f <= frames; f++) {
    float u = (float)f / frames;
    float e = 2.70158f * u * u * u - 1.70158f * u * u;  // easeInBack: dips below 0 first
    float s = CW * (1.0f - e), o = (CW - s) / 2;
    memcpy(composeBuffer, newB, IMAGE_SIZE);
    if (s >= 1.0f) {
      int sh = 6;  // shadow offset
      int x0 = max(0, (int)(o + sh)), x1 = min(CW, (int)(o + s + sh));
      int y0 = max(0, (int)(o + sh)), y1 = min(CH, (int)(o + s + sh));
      for (int y = y0; y < y1; y++)
        for (int x = x0; x < x1; x++) composeBuffer[y * CW + x] = shade565(composeBuffer[y * CW + x], 0.5f);
      blitScaled(oldB, o, o, s, s);
    }
    pushComposedFrame();
  }
}

// Infinite Zoom Out: the camera pulls back; the old cover becomes a small framed picture inside the new one.
void drawInfiniteZoomOut(const uint16_t* oldB, const uint16_t* newB) {
  const int frames = 30;
  for (int f = 1; f <= frames; f++) {
    float t = easeInOut((float)f / frames), k = powf(6.0f, 1.0f - t), sa = CW * k;
    float sb = 40.0f * k * (1.0f - clamp01((t - 0.8f) / 0.2f));  // the inner picture vanishes at the end
    blitScaled(newB, 120 - sa / 2, 120 - sa / 2, sa, sa);
    if (sb >= 2.0f) {
      int f0 = max(0, (int)(120 - sb / 2 - 2)), f1 = min(CW, (int)(120 + sb / 2 + 2));
      for (int y = f0; y < f1; y++)
        for (int x = f0; x < f1; x++) composeBuffer[y * CW + x] = 0xFFFF;
      blitScaled(oldB, 120 - sb / 2, 120 - sb / 2, sb, sb);
    }
    pushComposedFrame();
  }
}

// Vertically squash src into an h-row band centred on the screen, brightened toward white by k (0..32).
static void crtBand(const uint16_t* src, float h, uint32_t k) {
  memset(composeBuffer, 0, IMAGE_SIZE);
  int hh = max(2, (int)h), y0 = (CH - hh) / 2;
  for (int y = 0; y < hh; y++) {
    const uint16_t* s = src + ((y * CH) / hh) * CW;
    uint16_t* d = composeBuffer + (y0 + y) * CW;
    for (int x = 0; x < CW; x++) d[x] = blend565(s[x], 0xFFFF, k);
  }
}

// CRT Off: the old picture collapses to a glowing line, then a dot; the new one switches on from a line.
void drawCrtOff(const uint16_t* oldB, const uint16_t* newB) {
  const int frames = 32;
  for (int f = 1; f <= frames; f++) {
    float t = (float)f / frames;
    if (t < 0.4f) {
      float a = t / 0.4f;
      crtBand(oldB, CH * (1 - a) * (1 - a), (uint32_t)(a * 30));
    } else if (t < 0.6f) {
      float b = (t - 0.4f) / 0.2f;
      memset(composeBuffer, 0, IMAGE_SIZE);
      int w = max(4, (int)(CW * (1 - b))), x0 = (CW - w) / 2, hh = b > 0.8f ? 4 : 2;
      for (int y = 120 - hh / 2; y < 120 + hh / 2; y++)
        for (int x = x0; x < x0 + w; x++) composeBuffer[y * CW + x] = 0xDFFF;  // blue-white phosphor
    } else {
      float c = (t - 0.6f) / 0.4f, e = 1 - (1 - c) * (1 - c) * (1 - c);
      crtBand(newB, CH * e, (uint32_t)((1 - c) * 28));
    }
    pushComposedFrame();
  }
}

// Matrix Rain: green code columns fall; behind each head the new cover appears, tinted green at first.
void drawMatrixRain(const uint16_t* oldB, const uint16_t* newB) {
  const int frames = 32, col = 8, trail = 64;
  for (int f = 1; f <= frames; f++) {
    float t = (float)f / frames;
    for (int x0 = 0; x0 < CW; x0 += col) {
      float delay = cellHash(x0, 5) / 255.0f * 0.3f;
      int head = (int)(clamp01((t - delay) / 0.7f) * (CH + trail + 8)) - 8;
      for (int y = 0; y < CH; y++) {
        const uint16_t* o = oldB + y * CW + x0;
        const uint16_t* n = newB + y * CW + x0;
        uint16_t* d = composeBuffer + y * CW + x0;
        int dist = head - y;
        for (int x = 0; x < col; x++) {
          if (dist < 0) d[x] = o[x];
          else if (dist < 3) d[x] = 0xDFFB;  // white-green head
          else if (dist < trail) {
            uint16_t g = shade565(0x07E0, 0.25f + luma565(n[x]));
            if ((cellHash(x0 + 1000, (y >> 3) + f) & 7) == 0) g = 0xAFF5;  // flickering glyph
            d[x] = blend565(g, n[x], (uint32_t)((dist * 32) / trail));
          } else d[x] = n[x];
        }
      }
    }
    pushComposedFrame();
  }
}

// Neon Scan: a cyan scan line sweeps across with a glowing grid in its wake (light-cycle style).
void drawNeonScan(const uint16_t* oldB, const uint16_t* newB) {
  const int frames = 24;
  for (int f = 1; f <= frames; f++) {
    float p = easeInOut((float)f / frames) * (CW + 80) - 10;
    for (int y = 0; y < CH; y++) {
      uint16_t* d = composeBuffer + y * CW;
      for (int x = 0; x < CW; x++) {
        int i = y * CW + x;
        float dx = x - p;
        uint16_t c = dx < 0 ? newB[i] : oldB[i];
        if (dx < 0 && dx > -70 && (x % 20 == 0 || y % 20 == 0))
          c = blend565(c, 0x07FF, (uint32_t)(24 + dx * 24 / 70));  // grid fades behind the line
        float a = fabsf(dx);
        if (a < 2) c = 0xFFFF;
        else if (a < 10) c = blend565(c, 0x07FF, (uint32_t)(30 - a * 3));
        d[x] = c;
      }
    }
    pushComposedFrame();
  }
}

// Glass Sweep: a glossy diagonal glint (Aero / Aqua) sweeps across, swapping covers underneath.
void drawGlassSweep(const uint16_t* oldB, const uint16_t* newB) {
  const int frames = 22;
  for (int f = 1; f <= frames; f++) {
    float P = easeInOut((float)f / frames) * (478 + 120) - 60;
    for (int y = 0; y < CH; y++) {
      uint16_t* d = composeBuffer + y * CW;
      for (int x = 0; x < CW; x++) {
        int i = y * CW + x;
        float q = x + y - P, a = fabsf(q);
        uint16_t c = q < 0 ? newB[i] : oldB[i];
        if (a < 3) c = blend565(c, 0xFFFF, 28);
        else if (a < 40) c = blend565(c, 0xEFBF, (uint32_t)(20 - a / 2));
        d[x] = c;
      }
    }
    pushComposedFrame();
  }
}

// Pixelate: the old cover breaks into big pixels, switches, and the new one sharpens back.
void drawPixelate(const uint16_t* oldB, const uint16_t* newB) {
  const int frames = 20;
  for (int f = 1; f <= frames; f++) {
    float t = (float)f / frames;
    int bs = 1 + (int)(sinf(PI * t) * 23);
    const uint16_t* src = t < 0.5f ? oldB : newB;
    for (int y = 0; y < CH; y++) {
      const uint16_t* s = src + min(CH - 1, (y / bs) * bs + bs / 2) * CW;
      uint16_t* d = composeBuffer + y * CW;
      for (int x = 0; x < CW; x++) d[x] = s[min(CW - 1, (x / bs) * bs + bs / 2)];
    }
    pushComposedFrame();
  }
}

// VHS Glitch: tracking bands tear sideways with cyan/magenta fringes and noise lines.
void drawVhsGlitch(const uint16_t* oldB, const uint16_t* newB) {
  const int frames = 20;
  for (int f = 1; f <= frames; f++) {
    float t = (float)f / frames, amp = sinf(PI * t);
    const uint16_t* src = t < 0.5f ? oldB : newB;
    int chroma = (int)(amp * 6), bar = (f * 23) % CH;
    for (int y = 0; y < CH; y++) {
      int band = y >> 3, off = 0;
      if (cellHash(band, f + 99) < 90) off = (int)((cellHash(band, f) - 128) * amp * 0.25f);
      const uint16_t* row = src + y * CW;
      uint16_t* d = composeBuffer + y * CW;
      if (cellHash(y, f * 7) < (uint8_t)(10 * amp)) {  // noise line
        for (int x = 0; x < CW; x++) d[x] = (cellHash(x, y + f) & 1) ? 0xFFFF : 0x8410;
        continue;
      }
      bool tracking = y >= bar && y < bar + 10 && amp > 0.2f;
      for (int x = 0; x < CW; x++) {
        int sx = x - off;
        uint16_t c = (row[clampPx(sx - chroma)] & 0xF800) | (row[clampPx(sx)] & 0x07E0) |
                     (row[clampPx(sx + chroma)] & 0x001F);
        d[x] = tracking ? blend565(c, 0xFFFF, 10) : c;
      }
    }
    pushComposedFrame();
  }
}

String getTransitionName(TransitionType transition) {
  switch(transition) {
    case TRANSITION_WIPE_BOTTOM: return "Wipe Up";
    case TRANSITION_WIPE_LEFT: return "Wipe Right";
    case TRANSITION_WIPE_RIGHT: return "Wipe Left";
    case TRANSITION_CIRCULAR: return "Circular";
    case TRANSITION_CHECKERBOARD: return "Checkerboard";
    case TRANSITION_DIAGONAL: return "Diagonal";
    case TRANSITION_DIAGONAL_INVERSE: return "Diagonal Inverse";
    case TRANSITION_VENETIAN_V: return "Venetian V";
    case TRANSITION_FOUR_CORNER: return "Four Corner";
    case TRANSITION_ZOOM_BLOCKS: return "Zoom Blocks";
    case TRANSITION_HORIZONTAL_SPLIT: return "Horizontal Split";
    case TRANSITION_VERTICAL_SPLIT: return "Vertical Split";
    case TRANSITION_BARN_DOORS: return "Barn Doors";
    case TRANSITION_RANDOM_BLOCKS: return "Random Blocks";
    case TRANSITION_CHECKER_CASCADE: return "Checker Cascade";
    case TRANSITION_CARD_STACK: return "Card Stack";
    case TRANSITION_STATIC_DISSOLVE: return "Static Dissolve";
    case TRANSITION_DITHER_FADE: return "Dither Fade";
    case TRANSITION_PUSH_LEFT: return "Push Left";
    case TRANSITION_CROSSFADE: return "Crossfade";
    case TRANSITION_CARD_FLIP: return "Card Flip";
    case TRANSITION_TILE_FLIP: return "Tile Flip Wave";
    case TRANSITION_BLOCK_DROP: return "Block Drop";
    case TRANSITION_MELT: return "Melt";
    case TRANSITION_ZOOM_PUNCH: return "Zoom Punch";
    case TRANSITION_CORNER_PEEL: return "Corner Peel";
    case TRANSITION_SHATTER: return "Shatter";
    case TRANSITION_CUBE_TURN: return "Cube Turn";
    case TRANSITION_JELLY_DROP: return "Jelly Drop";
    case TRANSITION_TILE_SPIN: return "Tile Spin";
    case TRANSITION_INFINITE_ZOOM: return "Infinite Zoom";
    case TRANSITION_RGB_SPLIT: return "RGB Split";
    case TRANSITION_ACCORDION: return "Accordion";
    case TRANSITION_INK_BLEED: return "Ink Bleed";
    case TRANSITION_CRACK_SPLIT: return "Crack Split";
    case TRANSITION_SAND_PILE: return "Sand Pile";
    case TRANSITION_HALFTONE: return "Halftone";
    case TRANSITION_QUICK_IRIS: return "Quick Iris";
    case TRANSITION_DIAMOND_IRIS: return "Diamond Iris";
    case TRANSITION_HEART_IRIS: return "Heart Iris";
    case TRANSITION_CLOCK_SWEEP: return "Clock Sweep";
    case TRANSITION_BOW_TIE: return "Bow Tie";
    case TRANSITION_WIND: return "Wind";
    case TRANSITION_POLKA_DOTS: return "Polka Dots";
    case TRANSITION_RAIN_COLUMNS: return "Rain Columns";
    case TRANSITION_WAVE_WIPE: return "Wave Wipe";
    case TRANSITION_VENETIAN_H: return "Venetian H";
    case TRANSITION_SPIRAL_IN: return "Spiral In";
    case TRANSITION_LUMA_WIPE: return "Luma Wipe";
    case TRANSITION_PUSH_RIGHT: return "Push Right";
    case TRANSITION_CARD_STACK_LEFT: return "Card Stack Left";
    case TRANSITION_CUBE_TURN_REVERSE: return "Cube Turn Reverse";
    case TRANSITION_CORNER_PEEL_REVERSE: return "Corner Peel Reverse";
    case TRANSITION_ACCORDION_REVERSE: return "Accordion Reverse";
    case TRANSITION_BLOCK_RISE: return "Block Rise";
    case TRANSITION_MELT_UP: return "Melt Up";
    case TRANSITION_JELLY_RISE: return "Jelly Rise";
    case TRANSITION_ZOOM_OUT: return "Zoom Out";
    case TRANSITION_INFINITE_ZOOM_OUT: return "Infinite Zoom Out";
    case TRANSITION_CRT_OFF: return "CRT Off";
    case TRANSITION_MATRIX_RAIN: return "Matrix Rain";
    case TRANSITION_NEON_SCAN: return "Neon Scan";
    case TRANSITION_GLASS_SWEEP: return "Glass Sweep";
    case TRANSITION_PIXELATE: return "Pixelate";
    case TRANSITION_VHS_GLITCH: return "VHS Glitch";
    case TRANSITION_CUBE_UP: return "Cube Up";
    case TRANSITION_CUBE_DOWN: return "Cube Down";
    default:
      if (transition >= TRANSITION_VARIANT_FIRST && transition <= TRANSITION_VARIANT_LAST)
        return VARIANTS[transition - TRANSITION_VARIANT_FIRST].name;
      return "Unknown";
  }
}

// A retired slot that is forced by index draws the transition it duplicated.
static TransitionType resolveRetired(TransitionType t) {
  switch (t) {
    case TRANSITION_RETIRED_SLIDE: return TRANSITION_WIPE_RIGHT;
    case TRANSITION_RETIRED_CURTAIN: return TRANSITION_VERTICAL_SPLIT;
    case TRANSITION_RETIRED_ZIGZAG: return TRANSITION_BARN_DOORS;
    default: return t;
  }
}

// Draw `buffer` (the new cover) with transition `t`. Frame-composed transitions read the old
// cover from prevBuffer. Afterwards prevBuffer holds the new cover for the next transition.
static void runTransition(TransitionType t, uint16_t* buffer, int width, int height) {
  const bool canCompose = prevBuffer && composeBuffer;
  if (!canCompose && t >= TRANSITION_CARD_STACK) t = TRANSITION_WIPE_BOTTOM;
  if (canCompose && !panelShowsImage) memset(prevBuffer, 0, IMAGE_SIZE);  // old = black, not a stale cover
  const uint16_t* oldB = prevBuffer;
  // Resync the panel's drawing rectangle. Arduino_ST7789 skips CASET/RASET when the window equals
  // the last one it sent; if one of those commands was ever garbled on the wire, every later
  // same-sized draw went to the wrong rectangle (whole covers missing, single lines) until a
  // differently-sized draw happened. A 1x1 write here makes the next draw resend both. The pixel is
  // the new cover's own (0,0), which the transition paints anyway.
  gfx->drawPixel(0, 0, buffer[0]);
  // 81-88: an existing effect run mirrored (1 = left/right, 2 = top/bottom).
  TransitionType base = t;
  uint8_t flip = 0;
  switch (t) {
    case TRANSITION_PUSH_RIGHT: base = TRANSITION_PUSH_LEFT; flip = 1; break;
    case TRANSITION_CARD_STACK_LEFT: base = TRANSITION_CARD_STACK; flip = 1; break;
    case TRANSITION_CUBE_TURN_REVERSE: base = TRANSITION_CUBE_TURN; flip = 1; break;
    case TRANSITION_CORNER_PEEL_REVERSE: base = TRANSITION_CORNER_PEEL; flip = 1; break;
    case TRANSITION_ACCORDION_REVERSE: base = TRANSITION_ACCORDION; flip = 1; break;
    case TRANSITION_BLOCK_RISE: base = TRANSITION_BLOCK_DROP; flip = 2; break;
    case TRANSITION_MELT_UP: base = TRANSITION_MELT; flip = 2; break;
    case TRANSITION_JELLY_RISE: base = TRANSITION_JELLY_DROP; flip = 2; break;
    case TRANSITION_CUBE_DOWN: base = TRANSITION_CUBE_UP; flip = 2; break;
    default: break;
  }
  transSpeed = random(75, 131) / 100.0f;
  pushAcc = 0.0f;
  Serial.printf("Transition speed %.2fx\n", transSpeed);
  if (flip && canCompose) {
    // prevBuffer is overwritten with the new cover below anyway; `buffer` is mirrored back after.
    mirrorFrame(prevBuffer, flip);
    mirrorFrame(buffer, flip);
    composeFlip = flip;
  }
  if (t >= TRANSITION_VARIANT_FIRST && t <= TRANSITION_VARIANT_LAST) {
    const QuickVariant& v = VARIANTS[t - TRANSITION_VARIANT_FIRST];
    drawQuickMaskEx(v.map, v.flags, v.tint, oldB, buffer);
  } else switch (base) {
    case TRANSITION_ZOOM_OUT: drawZoomOut(oldB, buffer); break;
    case TRANSITION_INFINITE_ZOOM_OUT: drawInfiniteZoomOut(oldB, buffer); break;
    case TRANSITION_CRT_OFF: drawCrtOff(oldB, buffer); break;
    case TRANSITION_MATRIX_RAIN: drawMatrixRain(oldB, buffer); break;
    case TRANSITION_NEON_SCAN: drawNeonScan(oldB, buffer); break;
    case TRANSITION_GLASS_SWEEP: drawGlassSweep(oldB, buffer); break;
    case TRANSITION_PIXELATE: drawPixelate(oldB, buffer); break;
    case TRANSITION_VHS_GLITCH: drawVhsGlitch(oldB, buffer); break;
    case TRANSITION_CUBE_UP: drawCubeTurnV(oldB, buffer); break;
    case TRANSITION_WIPE_BOTTOM: drawWipeBottomToTop(buffer, width, height); break;
    case TRANSITION_WIPE_LEFT: drawWipeLeftToRight(buffer, width, height); break;
    case TRANSITION_WIPE_RIGHT: drawWipeRightToLeft(buffer, width, height); break;
    case TRANSITION_CIRCULAR: drawCircularWipe(buffer, width, height); break;
    case TRANSITION_CHECKERBOARD: drawCheckerboardDissolve(buffer, width, height); break;
    case TRANSITION_DIAGONAL: drawDiagonalWipe(buffer, width, height); break;
    case TRANSITION_DIAGONAL_INVERSE: drawDiagonalWipeInverse(buffer, width, height); break;
    case TRANSITION_VENETIAN_V: drawVenetianBlindsV(buffer, width, height); break;
    case TRANSITION_FOUR_CORNER: drawFourCornerWipe(buffer, width, height); break;
    case TRANSITION_ZOOM_BLOCKS: drawZoomBlocks(buffer, width, height); break;
    case TRANSITION_HORIZONTAL_SPLIT: drawHorizontalSplit(buffer, width, height); break;
    case TRANSITION_VERTICAL_SPLIT: drawVerticalSplit(buffer, width, height); break;
    case TRANSITION_BARN_DOORS: drawBarnDoors(buffer, width, height); break;
    case TRANSITION_RANDOM_BLOCKS: drawRandomBlocks(buffer, width, height); break;
    case TRANSITION_CHECKER_CASCADE: drawCheckerCascade(buffer, width, height); break;
    case TRANSITION_CARD_STACK: drawCardStack(oldB, buffer); break;
    case TRANSITION_STATIC_DISSOLVE: drawMaskDissolve(oldB, buffer, false); break;
    case TRANSITION_DITHER_FADE: drawMaskDissolve(oldB, buffer, true); break;
    case TRANSITION_PUSH_LEFT: drawPushLeft(oldB, buffer); break;
    case TRANSITION_CROSSFADE: drawCrossfade(oldB, buffer); break;
    case TRANSITION_CARD_FLIP: drawCardFlip(oldB, buffer); break;
    case TRANSITION_TILE_FLIP: drawTileFlip(oldB, buffer); break;
    case TRANSITION_BLOCK_DROP: drawBlockDrop(oldB, buffer); break;
    case TRANSITION_MELT: drawMelt(oldB, buffer); break;
    case TRANSITION_ZOOM_PUNCH: drawZoomPunch(oldB, buffer); break;
    case TRANSITION_CORNER_PEEL: drawCornerPeel(oldB, buffer); break;
    case TRANSITION_SHATTER: drawShatter(oldB, buffer); break;
    case TRANSITION_CUBE_TURN: drawCubeTurn(oldB, buffer); break;
    case TRANSITION_JELLY_DROP: drawJellyDrop(oldB, buffer); break;
    case TRANSITION_TILE_SPIN: drawTileSpin(oldB, buffer); break;
    case TRANSITION_INFINITE_ZOOM: drawInfiniteZoom(oldB, buffer); break;
    case TRANSITION_RGB_SPLIT: drawRgbSplit(oldB, buffer); break;
    case TRANSITION_ACCORDION: drawAccordion(oldB, buffer); break;
    case TRANSITION_INK_BLEED: drawInkBleed(oldB, buffer); break;
    case TRANSITION_CRACK_SPLIT: drawCrackSplit(oldB, buffer); break;
    case TRANSITION_SAND_PILE: drawSandPile(oldB, buffer); break;
    case TRANSITION_HALFTONE: drawHalftone(oldB, buffer); break;
    case TRANSITION_QUICK_IRIS: drawQuickMask(0, oldB, buffer); break;
    case TRANSITION_DIAMOND_IRIS: drawQuickMask(1, oldB, buffer); break;
    case TRANSITION_HEART_IRIS: drawQuickMask(2, oldB, buffer); break;
    case TRANSITION_CLOCK_SWEEP: drawQuickMask(3, oldB, buffer); break;
    case TRANSITION_BOW_TIE: drawQuickMask(4, oldB, buffer); break;
    case TRANSITION_WIND: drawQuickMask(5, oldB, buffer); break;
    case TRANSITION_POLKA_DOTS: drawQuickMask(6, oldB, buffer); break;
    case TRANSITION_RAIN_COLUMNS: drawQuickMask(7, oldB, buffer); break;
    case TRANSITION_WAVE_WIPE: drawQuickMask(8, oldB, buffer); break;
    case TRANSITION_VENETIAN_H: drawQuickMask(9, oldB, buffer); break;
    case TRANSITION_SPIRAL_IN: drawQuickMask(10, oldB, buffer); break;
    case TRANSITION_LUMA_WIPE: drawQuickMask(11, oldB, buffer); break;
    default: drawWipeBottomToTop(buffer, width, height); break;
  }
  if (composeFlip) {
    composeFlip = 0;
    mirrorFrame(buffer, flip);
  }
  // Every frame-composed transition ends on the exact new frame.
  if (canCompose && t >= TRANSITION_CARD_STACK) gfx->draw16bitRGBBitmap(0, 0, buffer, width, height);
  if (canCompose) memcpy(prevBuffer, buffer, IMAGE_SIZE);
  panelShowsImage = true;
  Serial.println("Transition complete!");
}

// True if the app left transition `t` switched on (BLE_PROTOCOL 1.12 mask).
static bool transitionEnabled(int t) {
  if (t < 0 || t >= TRANSITION_COUNT) return false;
  if (t < 32) return (transitionMaskLo >> t) & 1u;
  if (t < 64) return (transitionMaskHi >> (t - 32)) & 1u;
  if (t < 96) return (transitionMaskW2 >> (t - 64)) & 1u;
  return (transitionMaskW3 >> (t - 96)) & 1u;
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
    // 1.13 threshold-map variants cost the same as the quick set's own maps.
    if (t >= TRANSITION_VARIANT_FIRST && t <= TRANSITION_VARIANT_LAST) return true;
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
#define STATUS_LED_MAX 64  // ceiling out of 255 (~25%; was 26). Owner wanted it brighter 2026-11-22.
                           // Full WS2812 is blinding through a thin case.

#define LED_RGB_BLUE   0x0050FF
#define LED_RGB_ORANGE 0xFF5A00
#define LED_RGB_GREEN  0x00FF28
#define LED_RGB_RED    0xFF0000

enum LedMode : uint8_t { LED_OFF, LED_CACHE, LED_TRANSFER, LED_DONE, LED_ERROR };
static LedMode ledMode = LED_OFF;
static unsigned long ledModeSince = 0;
static uint32_t ledLastWritten = 0xFFFFFFFF;

static void ledWriteRaw(uint8_t r, uint8_t g, uint8_t b) {
  uint32_t c = ((uint32_t)r << 16) | ((uint32_t)g << 8) | b;
  if (c == ledLastWritten) return;  // skip redundant RMT writes (loop runs ~100x/s)
  ledLastWritten = c;
  neopixelWrite(STATUS_LED_PIN, r, g, b);  // core handles the WS2812 GRB byte order
}

// level 0..255 is scaled into 0..STATUS_LED_MAX.
static void ledShow(uint32_t rgb, uint16_t level) {
  uint32_t k = (uint32_t)level * STATUS_LED_MAX / 255;
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
    case LED_TRANSFER: {
      // Base brightness follows progress (40% -> 100%); a 1.2 s triangle pulse rides on top.
      // Progress is against this frame's wire size: a compressed frame (1.11) is smaller than
      // IMAGE_SIZE. Both are written on BTC_TASK; a torn read only nudges brightness.
      uint32_t want = expectedSize;
      if (want == 0 || want > IMAGE_SIZE) want = IMAGE_SIZE;
      uint32_t got = receivedBytes;
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
        ledSetMode(LED_OFF);  // a fresh transfer (orange) follows
        Serial.println("ERROR: Cache load failed — reporting miss so the client sends fresh");
        // The client is waiting on the Cache characteristic, not the Image one; without this
        // reply it times out instead of falling back to a normal transfer.
        uint8_t response = 0x00;
        pCacheChar->setValue(&response, 1);
        pCacheChar->notify();
      }
    } else {
      Serial.println("BLE: Cache MISS");
      ledSetMode(LED_OFF);  // the phone now downloads + converts; orange starts with the first chunk
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
    ledSetMode(LED_DONE);

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

    // Update to connected state (yes=green, no=black - connected!)
    showingStartupScreen = false;
    showBluetoothConnectionScreen(GREEN, BLACK);

    // Clear and show ready message - LARGER & CENTERED
    showReadyScreen();

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
