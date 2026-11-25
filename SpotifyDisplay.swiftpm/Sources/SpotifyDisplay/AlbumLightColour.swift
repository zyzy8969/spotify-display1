import Foundation

/// BLE_PROTOCOL 1.23 "album" song light: one LED colour that matches a cover.
///
/// Reads the frame the board shows (240x240 little-endian RGB565), so cache hits, fresh sends and
/// photos all work without another download. Vivid areas win over greys, black and white: each sampled
/// pixel votes for one of 24 hue buckets, weighted by saturation and brightness, and the strongest
/// bucket (with its two neighbours) gives the hue. The result is pushed to full brightness and a good
/// saturation, because one small LED shows dark or washed-out colours as muddy grey. A cover with
/// almost no colour (black and white) gets white.
enum AlbumLightColour {
    static let grey: UInt32 = 0xFFFFFF
    private static let buckets = 24
    private static let step = 7  // every 7th pixel: ~8,200 samples of 57,600

    /// 0xRRGGBB for the LED.
    static func from(rgb565 frame: Data) -> UInt32 {
        let pixels = frame.count / 2
        guard pixels > 0 else { return grey }
        var weight = [Double](repeating: 0, count: buckets)
        var sumR = [Double](repeating: 0, count: buckets)
        var sumG = [Double](repeating: 0, count: buckets)
        var sumB = [Double](repeating: 0, count: buckets)
        var samples = 0
        frame.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let b = raw.bindMemory(to: UInt8.self)
            var i = 0
            while i < pixels {
                defer { i += step }
                samples += 1
                let v = UInt16(b[2 * i]) | (UInt16(b[2 * i + 1]) << 8)
                let r = Double((v >> 11) & 0x1F) / 31
                let g = Double((v >> 5) & 0x3F) / 63
                let bl = Double(v & 0x1F) / 31
                let mx = max(r, g, bl), mn = min(r, g, bl), d = mx - mn
                guard mx > 0.12, d > 0 else { continue }
                let s = d / mx
                guard s > 0.18 else { continue }
                let h = hue(r: r, g: g, b: bl, mx: mx, d: d)
                let k = min(buckets - 1, Int(h * Double(buckets)))
                let w = s * s * mx
                weight[k] += w
                sumR[k] += r * w
                sumG[k] += g * w
                sumB[k] += bl * w
            }
        }
        // Almost no colour anywhere: a black-and-white cover.
        let total = weight.reduce(0, +)
        guard samples > 0, total > Double(samples) * 0.01 else { return grey }
        var best = 0
        var bestScore = -1.0
        for k in 0..<buckets {
            let score = weight[(k + buckets - 1) % buckets] + weight[k] + weight[(k + 1) % buckets]
            if score > bestScore { bestScore = score; best = k }
        }
        var w = 0.0, r = 0.0, g = 0.0, bl = 0.0
        for k in [(best + buckets - 1) % buckets, best, (best + 1) % buckets] {
            w += weight[k]; r += sumR[k]; g += sumG[k]; bl += sumB[k]
        }
        guard w > 0 else { return grey }
        r /= w; g /= w; bl /= w
        let mx = max(r, g, bl), d = mx - min(r, g, bl)
        guard mx > 0, d > 0 else { return grey }
        let h = hue(r: r, g: g, b: bl, mx: mx, d: d)
        let s = min(1, max(0.6, d / mx * 1.2))
        return hsvToHex(h: h, s: s, v: 1)
    }

    /// Hue 0..<1 (0 = red).
    private static func hue(r: Double, g: Double, b: Double, mx: Double, d: Double) -> Double {
        var h: Double
        if mx == r { h = (g - b) / d }
        else if mx == g { h = 2 + (b - r) / d }
        else { h = 4 + (r - g) / d }
        h /= 6
        if h < 0 { h += 1 }
        return h >= 1 ? 0 : h
    }

    static func hsvToHex(h: Double, s: Double, v: Double) -> UInt32 {
        let i = Int(h * 6) % 6
        let f = h * 6 - Double(Int(h * 6))
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        let (r, g, b): (Double, Double, Double)
        switch i {
        case 0: (r, g, b) = (v, t, p)
        case 1: (r, g, b) = (q, v, p)
        case 2: (r, g, b) = (p, v, t)
        case 3: (r, g, b) = (p, q, v)
        case 4: (r, g, b) = (t, p, v)
        default: (r, g, b) = (v, p, q)
        }
        func byte(_ x: Double) -> UInt32 { UInt32(max(0, min(255, (x * 255).rounded()))) }
        return (byte(r) << 16) | (byte(g) << 8) | byte(b)
    }
}
