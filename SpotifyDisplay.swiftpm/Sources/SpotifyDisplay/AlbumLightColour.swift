import Foundation

/// BLE_PROTOCOL 1.23 "album" song light: one LED colour that matches a cover.
///
/// Reads the frame the board shows (240x240 little-endian RGB565), so cache hits, fresh sends and
/// photos all work without another download.
///
/// Owner, 2026-11-24: the colour covering the most of the cover wins ("most shown colour"). Each sampled
/// pixel with real colour votes for one of 24 hue buckets, one vote each; black, white and greys don't
/// vote, because one small LED can't show them (they come out as white or off). The strongest bucket,
/// with its two neighbours, gives the hue. If under 3% of the cover has real colour, the most vivid
/// colour is used instead (a mostly black cover with a red logo gets red); with almost no colour at all
/// (a black-and-white cover) it is white. The result is pushed to full brightness and a good saturation:
/// the LED shows dark or washed-out colours as muddy grey (navy becomes blue, brown becomes orange).
enum AlbumLightColour {
    static let grey: UInt32 = 0xFFFFFF
    private static let buckets = 24
    private static let step = 7  // every 7th pixel: ~8,200 samples of 57,600

    private struct Votes {
        var weight = [Double](repeating: 0, count: AlbumLightColour.buckets)
        var r = [Double](repeating: 0, count: AlbumLightColour.buckets)
        var g = [Double](repeating: 0, count: AlbumLightColour.buckets)
        var b = [Double](repeating: 0, count: AlbumLightColour.buckets)
        var voters = 0
        var total: Double { weight.reduce(0, +) }

        mutating func add(bucket k: Int, r: Double, g: Double, b: Double, w: Double) {
            weight[k] += w; self.r[k] += r * w; self.g[k] += g * w; self.b[k] += b * w
            voters += 1
        }
    }

    /// 0xRRGGBB for the LED.
    static func from(rgb565 frame: Data) -> UInt32 {
        let pixels = frame.count / 2
        guard pixels > 0 else { return grey }
        var area = Votes()   // one vote per clearly coloured pixel
        var vivid = Votes()  // fallback: weighted towards saturated, bright pixels
        var samples = 0
        frame.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let px = raw.bindMemory(to: UInt8.self)
            var i = 0
            while i < pixels {
                defer { i += step }
                samples += 1
                let v = UInt16(px[2 * i]) | (UInt16(px[2 * i + 1]) << 8)
                let r = Double((v >> 11) & 0x1F) / 31
                let g = Double((v >> 5) & 0x3F) / 63
                let b = Double(v & 0x1F) / 31
                let mx = max(r, g, b), d = mx - min(r, g, b)
                guard mx > 0.12, d > 0 else { continue }
                let s = d / mx
                guard s > 0.18 else { continue }
                let k = min(buckets - 1, Int(hue(r: r, g: g, b: b, mx: mx, d: d) * Double(buckets)))
                vivid.add(bucket: k, r: r, g: g, b: b, w: s * s * mx)
                if s > 0.25 && mx > 0.2 { area.add(bucket: k, r: r, g: g, b: b, w: 1) }
            }
        }
        guard samples > 0 else { return grey }
        if Double(area.voters) >= Double(samples) * 0.03 { return pick(area) }
        if vivid.total > Double(samples) * 0.01 { return pick(vivid) }
        return grey
    }

    /// The strongest hue (bucket plus neighbours), at full brightness and a good saturation.
    private static func pick(_ votes: Votes) -> UInt32 {
        var best = 0
        var bestScore = -1.0
        for k in 0..<buckets {
            let score = votes.weight[(k + buckets - 1) % buckets] + votes.weight[k] + votes.weight[(k + 1) % buckets]
            if score > bestScore { bestScore = score; best = k }
        }
        var w = 0.0, r = 0.0, g = 0.0, b = 0.0
        for k in [(best + buckets - 1) % buckets, best, (best + 1) % buckets] {
            w += votes.weight[k]; r += votes.r[k]; g += votes.g[k]; b += votes.b[k]
        }
        guard w > 0 else { return grey }
        r /= w; g /= w; b /= w
        let mx = max(r, g, b), d = mx - min(r, g, b)
        guard mx > 0, d > 0 else { return grey }
        let h = hue(r: r, g: g, b: b, mx: mx, d: d)
        // Owner, 2026-11-24: the LED should look like the cover on the screen. Keep the cover's own
        // saturation (a small boost only; the old 60% floor made muted covers too vivid) at full brightness.
        let s = min(1, d / mx * 1.15)
        return ledGamma(hsvToHex(h: h, s: s, v: 1))
    }

    /// Screen colours are gamma-encoded (sRGB-like); the WS2812's PWM is linear, so a mid value looks far
    /// too bright on it (orange turns yellow, pastels go white). Decode each channel with gamma 2.2 so the
    /// LED shows the colour the screen does. The brightest channel stays 255.
    static func ledGamma(_ hex: UInt32) -> UInt32 {
        func lin(_ c: UInt32) -> UInt32 {
            UInt32((pow(Double(c) / 255, 2.2) * 255).rounded())
        }
        return (lin(hex >> 16 & 0xFF) << 16) | (lin(hex >> 8 & 0xFF) << 8) | lin(hex & 0xFF)
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
