// Shared transition core. See include/transitions_core.h. The transition bodies below were moved
// verbatim from src/main.cpp (2026-11-22); the shims at the top let the same text run anywhere.
#include "transitions_core.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

// Everything up to the public API is in an anonymous namespace: internal linkage, so none of
// these names (drawWipeBottomToTop, gfx, composeBuffer, ...) can clash with the firmware's or the
// app's own symbols.
namespace {

// ---- Shims: the names the moved code uses, routed through the TxPanel ----
static const TxPanel* g_panel = nullptr;
static uint16_t* composeBuffer = nullptr;
static uint32_t g_rng = 1;
// Speed factor for the current tx_run (BLE_PROTOCOL 1.14): 1 = as designed, 2 = twice as fast,
// 0.5 = half speed. Frame-composed transitions run proportionally fewer / more frames; the older
// drawn ones scale their pauses (the board also stretches their drawing time when slowing down).
static float g_speed = 1.0f;
static inline int tx_frames(int n) {
  int f = (int)((float)n / g_speed + 0.5f);
  return f < 2 ? 2 : f;
}
static inline uint32_t tx_scaled_us(uint32_t us) { return (uint32_t)((float)us / g_speed + 0.5f); }

struct TxGfx {
  void draw16bitRGBBitmap(int16_t x, int16_t y, const uint16_t* px, int16_t w, int16_t h) {
    g_panel->bitmap(g_panel->ctx, x, y, px, w, h);
  }
  void drawPixel(int16_t x, int16_t y, uint16_t c) { g_panel->pixel(g_panel->ctx, x, y, c); }
};
static TxGfx g_gfx;
static TxGfx* const gfx = &g_gfx;

static inline void tx_wait_us(uint32_t us) { g_panel->waitUs(g_panel->ctx, us); }
static inline void* tx_alloc_large(size_t n) {
  return g_panel->allocLarge ? g_panel->allocLarge(g_panel->ctx, n) : malloc(n);
}
// xorshift32: same sequence on the board and in the app for the same seed.
static inline long tx_random(long lo, long hi) {
  g_rng ^= g_rng << 13; g_rng ^= g_rng >> 17; g_rng ^= g_rng << 5;
  if (hi <= lo) return lo;
  return lo + (long)(g_rng % (uint32_t)(hi - lo));
}

#define delayMicroseconds(us) tx_wait_us(tx_scaled_us((uint32_t)(us)))
#define delay(ms) tx_wait_us(tx_scaled_us((uint32_t)(ms) * 1000u))
#define random(lo, hi) tx_random((lo), (hi))
#define ps_malloc(n) tx_alloc_large(n)
#undef min
#undef max
#define min(a, b) ((a) < (b) ? (a) : (b))
#define max(a, b) ((a) > (b) ? (a) : (b))
#ifndef PI
#define PI 3.1415926535897932384626433832795  // Arduino's value, so float maths match
#endif

#define DISPLAY_WIDTH TX_WIDTH
#define DISPLAY_HEIGHT TX_HEIGHT
#define IMAGE_SIZE (DISPLAY_WIDTH * DISPLAY_HEIGHT * 2)
#define TRANSITION_WIPE_DELAY_US 500
#define CIRCULAR_WIPE_MAX_RADIUS 170

// ==================================================
// TRANSITION FUNCTIONS (moved verbatim from src/main.cpp)
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
  const int steps = tx_frames(30);
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

static inline void pushComposedFrame() {
  gfx->draw16bitRGBBitmap(0, 0, composeBuffer, CW, CH);
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
  const int frames = tx_frames(26);
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
  const int frames = tx_frames(18);
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
  const int frames = tx_frames(24);
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
  const int frames = tx_frames(16);
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
  const int frames = tx_frames(24);
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
  const int n = 6, ts = CW / n, frames = tx_frames(30);
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
  const int n = 6, bs = CW / n, frames = tx_frames(36);
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
  const int col = 4, frames = tx_frames(30);
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
  const int frames = tx_frames(26);
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
  const int frames = tx_frames(28);
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
  const int frames = tx_frames(32);
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
      // Everything below is affine in the screen pixel (x, y): the source point (sx, sy) inside the
      // unmoved shard and its barycentric weights w0, w1 (w2 = 1 - w0 - w1). So per frame and shard we
      // compute each one's value at (0, 0) and its x/y slopes once, solve each row's inside-the-shard
      // span directly, and walk only that span with additions. The old loop tested every pixel of the
      // bounding box (about twice the shard) with 3 divides and a rotation each.
      // Source point: sx = s.cx + cs*rx + sn*ry, sy = s.cy - sn*rx + cs*ry, rx = x+0.5-s.cx-ox, ry = y+0.5-s.cy-oy.
      const float qx = 0.5f - s.cx - ox, qy = 0.5f - s.cy - oy;
      const float sx00 = s.cx + cs * qx + sn * qy, sy00 = s.cy - sn * qx + cs * qy;
      const float sxdx = cs, sxdy = sn, sydx = -sn, sydy = cs;
      // w0 = ((bx-ax)(sy-ay) - (by-ay)(sx-ax)) / area; w1 likewise with (b, c). Linear in (sx, sy).
      const float ia = 1.0f / s.area;
      const float a0x = -(s.by - s.ay) * ia, a0y = (s.bx - s.ax) * ia;
      const float a0c = ((s.by - s.ay) * s.ax - (s.bx - s.ax) * s.ay) * ia;
      const float a1x = -(s.cy2 - s.by) * ia, a1y = (s.cx2 - s.bx) * ia;
      const float a1c = ((s.cy2 - s.by) * s.bx - (s.cx2 - s.bx) * s.by) * ia;
      const float w0dx = a0x * sxdx + a0y * sydx, w0dy = a0x * sxdy + a0y * sydy;
      const float w1dx = a1x * sxdx + a1y * sydx, w1dy = a1x * sxdy + a1y * sydy;
      const float w0_00 = a0x * sx00 + a0y * sy00 + a0c, w1_00 = a1x * sx00 + a1y * sy00 + a1c;
      const float w2dx = -w0dx - w1dx;
      const uint8_t crackAmt = lt > 0 ? 14 : 24;
      for (int y = y0; y <= y1; y++) {
        // Row values at x = 0, then the x range where all three weights are >= 0.
        float w0r = w0_00 + w0dy * y, w1r = w1_00 + w1dy * y, w2r = 1.0f - w0r - w1r;
        float lo = (float)x0, hi = (float)x1;
        bool empty = false;
        const float wr[3] = {w0r, w1r, w2r}, wd[3] = {w0dx, w1dx, w2dx};
        for (int e = 0; e < 3 && !empty; e++) {
          if (wd[e] > 1e-7f)       lo = fmaxf(lo, -wr[e] / wd[e]);
          else if (wd[e] < -1e-7f) hi = fminf(hi, -wr[e] / wd[e]);
          else if (wr[e] < 0)      empty = true;
        }
        if (empty) continue;
        int xs = max(x0, (int)ceilf(lo)), xe = min(x1, (int)floorf(hi));
        if (xs > xe) continue;
        float sx = sx00 + sxdx * xs + sxdy * y, sy = sy00 + sydx * xs + sydy * y;
        uint16_t* out = composeBuffer + y * CW + xs;
        if (!cracks) {
          for (int x = xs; x <= xe; x++, sx += sxdx, sy += sydx)
            *out++ = oldB[clampPx((int)sy) * CW + clampPx((int)sx)];
        } else {
          float w0 = w0r + w0dx * xs, w1 = w1r + w1dx * xs, w2 = 1.0f - w0 - w1;
          for (int x = xs; x <= xe; x++, sx += sxdx, sy += sydx, w0 += w0dx, w1 += w1dx, w2 += w2dx) {
            uint16_t c = oldB[clampPx((int)sy) * CW + clampPx((int)sx)];
            if (fminf(w0, fminf(w1, w2)) < 0.035f) c = blend565(c, 0xFFFF, crackAmt);
            *out++ = c;
          }
        }
      }
    }
    pushComposedFrame();
  }
}

// Cube Turn: both covers on the faces of a cube turning 90 degrees, with perspective and shading.
void drawCubeTurn(const uint16_t* oldB, const uint16_t* newB) {
  const int frames = tx_frames(26);
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

// Jelly Drop: new cover falls in, squashes on impact and wobbles until it settles.
void drawJellyDrop(const uint16_t* oldB, const uint16_t* newB) {
  const int frames = tx_frames(34);
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
  const int frames = tx_frames(32);
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
  const int frames = tx_frames(30);
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
  const int frames = tx_frames(22);
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
  const int frames = tx_frames(24), n = 8, pw = CW / n;
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
  const int frames = tx_frames(28);
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
  const int crackFrames = tx_frames(10), splitFrames = tx_frames(22);
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
  const int frames = tx_frames(36);
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
  const int frames = tx_frames(28);
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
// QUICK TRANSITIONS (moved verbatim from src/main.cpp)
// ==================================================

#define QUICK_FRAMES tx_frames(10)
static uint8_t* quickMaps[12] = {nullptr};

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

void drawQuickMask(int id, const uint16_t* oldB, const uint16_t* newB) {
  static uint8_t* lumaMap = nullptr;
  const uint8_t* m;
  if (id == 11) {  // Luma Wipe: dark parts of the new cover arrive first, highlights last
    if (!lumaMap) lumaMap = (uint8_t*)ps_malloc(CW * CH);
    if (!lumaMap) { drawPushLeft(oldB, newB); return; }
    for (int i = 0; i < CW * CH; i++) lumaMap[i] = (uint8_t)(luma565(newB[i]) * 250.0f);
    m = lumaMap;
  } else {
    m = getQuickMap(id);
    if (!m) { drawPushLeft(oldB, newB); return; }
  }
  for (int f = 1; f <= QUICK_FRAMES; f++) {
    int level = (f * 256) / QUICK_FRAMES;
    for (int i = 0; i < CW * CH; i++) composeBuffer[i] = m[i] < level ? newB[i] : oldB[i];
    pushComposedFrame();
  }
}


static const char* txNameOf(TransitionType transition) {
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
    default: return "Unknown";
  }
}

// A retired slot that is forced by index draws the transition it duplicated.
static TransitionType resolveRetiredCore(TransitionType t) {
  switch (t) {
    case TRANSITION_RETIRED_SLIDE: return TRANSITION_WIPE_RIGHT;
    case TRANSITION_RETIRED_CURTAIN: return TRANSITION_VERTICAL_SPLIT;
    case TRANSITION_RETIRED_ZIGZAG: return TRANSITION_BARN_DOORS;
    default: return t;
  }
}


}  // namespace

// ==================================================
// Public API
// ==================================================

extern "C" void tx_set_speed(float speed) {
  if (!(speed > 0.0f)) speed = 1.0f;  // also catches NaN
  g_speed = speed < 0.25f ? 0.25f : (speed > 4.0f ? 4.0f : speed);
}

extern "C" const char* tx_name(int t) {
  if (t < 0 || t >= TRANSITION_COUNT) return "Unknown";
  return txNameOf((TransitionType)t);
}

extern "C" int tx_resolve(int t) {
  if (t < 0 || t >= TRANSITION_COUNT) return t;
  return (int)resolveRetiredCore((TransitionType)t);
}

extern "C" int tx_run(const TxPanel* panel, int ti, const uint16_t* oldFrame, const uint16_t* newFrame,
                      uint16_t* compose, uint32_t seed) {
  g_panel = panel;
  composeBuffer = compose;
  g_rng = seed ? seed : 0x9E3779B9u;
  TransitionType t = (ti < 0 || ti >= TRANSITION_COUNT) ? TRANSITION_WIPE_BOTTOM : (TransitionType)tx_resolve(ti);
  const bool canCompose = oldFrame && compose;
  if (!canCompose && t >= TRANSITION_CARD_STACK) t = TRANSITION_WIPE_BOTTOM;
  const uint16_t* oldB = oldFrame;
  uint16_t* buffer = (uint16_t*)newFrame;  // the moved code takes it non-const; it never writes it
  const int width = DISPLAY_WIDTH, height = DISPLAY_HEIGHT;
  switch (t) {
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
  // Every frame-composed transition ends on the exact new frame.
  if (canCompose && t >= TRANSITION_CARD_STACK) gfx->draw16bitRGBBitmap(0, 0, buffer, width, height);
  g_panel = nullptr;
  return (int)t;
}
