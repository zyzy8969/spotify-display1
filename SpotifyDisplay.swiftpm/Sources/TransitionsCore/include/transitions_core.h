// Shared transition core: the board's cover transitions, compiled by BOTH the ESP32 firmware
// (src/transitions_core_fw.cpp) and the iOS app (Swift calls tx_run to render the same frames).
// Keep it free of Arduino and Apple APIs: all output goes through TxPanel.
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

#define TX_WIDTH 240
#define TX_HEIGHT 240

// Transition effects enum. Values are the BLE header's transitionIndex (docs/BLE_PROTOCOL.md),
// so they are fixed: never renumber. Retired slots stay reserved and draw their twin when forced.
typedef enum TransitionType {
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
  // 1.15 (build 46): 52-80 are threshold-map variants (VARIANTS table: inverses, mirrors, neon edges; quick),
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
  // 1.15 slideshow set, after PowerPoint 2003 / 2010 and Google Slides. 106-110 are quick (threshold maps).
  TRANSITION_COMB_H = 99,
  TRANSITION_COMB_V = 100,
  TRANSITION_COVER_DOWN = 101,
  TRANSITION_UNCOVER_LEFT = 102,
  TRANSITION_UNCOVER_DOWN = 103,
  TRANSITION_FADE_BLACK = 104,
  TRANSITION_NEWSFLASH = 105,
  TRANSITION_STRIPS = 106,
  TRANSITION_WEDGE = 107,
  TRANSITION_CHECKER_ACROSS = 108,
  TRANSITION_HONEYCOMB = 109,
  TRANSITION_GLITTER = 110,
  TRANSITION_SHRED = 111,
  TRANSITION_GALLERY = 112,
  TRANSITION_DOORS = 113,
  TRANSITION_RIPPLE = 114,
  TRANSITION_FLASH = 115,
  TRANSITION_FLY_THROUGH = 116,
  TRANSITION_COUNT                // Total number of slots (including retired)
} TransitionType;

static inline bool isRetiredTransition(TransitionType t) {
  return t == TRANSITION_RETIRED_SLIDE || t == TRANSITION_RETIRED_CURTAIN ||
         t == TRANSITION_RETIRED_ZIGZAG ||
         (t >= 75 && t <= 80) ||          // neon edges: owner didn't want them (2026-11-22)
         t == TRANSITION_MATRIX_RAIN;     // owner didn't like it (2026-11-22)
}


/// Where a transition draws. The board points these at the panel; the app at an in-memory frame.
typedef struct TxPanel {
  void* ctx;
  /// Write a w x h block of RGB565 (row-major, stride w) at (x, y).
  void (*bitmap)(void* ctx, int16_t x, int16_t y, const uint16_t* px, int16_t w, int16_t h);
  void (*pixel)(void* ctx, int16_t x, int16_t y, uint16_t c);
  /// The transition pausing between steps (real delay on the board, virtual time in the app).
  void (*waitUs)(void* ctx, uint32_t us);
  /// Large lookup tables (57.6 KB each, kept for reuse). NULL = malloc.
  void* (*allocLarge)(void* ctx, size_t bytes);
} TxPanel;

/// Speed for the following tx_run calls (BLE_PROTOCOL 1.14): 1 = as designed, 2 = twice as fast,
/// 0.5 = half speed; clamped to 0.25...4. Frame-composed transitions draw proportionally fewer or
/// more frames; the older ones scale their pauses. Stays set until changed. Not thread-safe.
void tx_set_speed(float speed);

/// Name the firmware announces for index t ("Unknown" for retired / out of range).
const char* tx_name(int t);
/// Retired slots draw their twin.
int tx_resolve(int t);
/// Draws newFrame with transition t. oldFrame = picture on the panel before it (all black if none);
/// compose = TX_WIDTH x TX_HEIGHT scratch frame. With oldFrame or compose NULL the frame-composed
/// transitions (index >= Card Stack) fall back to Wipe Up, as on the board. seed drives the random
/// choices (Random Blocks, Crack Split). Returns the transition actually drawn. Not thread-safe.
int tx_run(const TxPanel* panel, int t, const uint16_t* oldFrame, const uint16_t* newFrame,
           uint16_t* compose, uint32_t seed);

#ifdef __cplusplus
}
#endif
