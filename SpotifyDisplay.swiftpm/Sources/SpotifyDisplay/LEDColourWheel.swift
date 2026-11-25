import SwiftUI

/// A colour wheel that only offers colours the keychain's status LED can show (owner, 2026-11-24).
///
/// The LED makes a colour by mixing red, green and blue light, so it can show any hue and any amount of
/// white mixed in, but not darkness: dark colours, greys and browns just come out as a dimmer bright
/// colour (how bright is the status-light slider's job). So the wheel has hue around the ring and
/// strength from the white centre to the full colour at the edge, always at full brightness, and no
/// opacity. The picked colour is stored as the screen colour shown here; `LightPalette.ledHex`
/// gamma-decodes it on the way to the LED so the LED looks like this.
struct LEDColourWheelSheet: View {
    let title: String
    let initialHex: UInt32
    /// Called on every change while dragging (the BLE write is throttled) and on Done.
    let onChange: (UInt32) -> Void

    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var hue: Double = 0
    @State private var saturation: Double = 1

    private var hex: UInt32 { AlbumLightColour.hsvToHex(h: hue, s: saturation, v: 1) }

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Text(title)
                    .themeText(.row)
                    .foregroundStyle(theme.ink)
                Spacer()
                Button {
                    onChange(hex)
                    dismiss()
                } label: {
                    Text("Done")
                        .themeText(.row)
                        .foregroundStyle(theme.ink)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
            }
            LEDColourWheel(hue: $hue, saturation: $saturation) { onChange(hex) }
                .frame(width: 260, height: 260)
            HStack(spacing: 10) {
                Circle()
                    .fill(Color(hex: hex))
                    .overlay(Circle().stroke(theme.ringOff, lineWidth: 1))
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                Text("Only colours the light can make. Set how bright with the status-light slider.")
                    .themeText(.footnote)
                    .foregroundStyle(theme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .background(theme.background.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .onAppear {
            let (h, s) = Self.hueSaturation(initialHex)
            hue = h
            saturation = s
        }
    }

    /// Hue 0..<1 and saturation 0...1 of a colour (its brightness is dropped: the wheel is all full
    /// brightness, so a dark saved colour opens on its bright version).
    static func hueSaturation(_ hex: UInt32) -> (Double, Double) {
        let r = Double(hex >> 16 & 0xFF) / 255, g = Double(hex >> 8 & 0xFF) / 255, b = Double(hex & 0xFF) / 255
        let mx = max(r, g, b), d = mx - min(r, g, b)
        guard mx > 0, d > 0 else { return (0, 0) }
        var h: Double
        if mx == r { h = (g - b) / d } else if mx == g { h = 2 + (b - r) / d } else { h = 4 + (r - g) / d }
        h /= 6
        if h < 0 { h += 1 }
        return (h >= 1 ? 0 : h, d / mx)
    }
}

/// The disc itself: hue by angle (red at 3 o'clock, going clockwise), white at the centre. Drag or tap.
struct LEDColourWheel: View {
    @Binding var hue: Double
    @Binding var saturation: Double
    let changed: () -> Void

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let radius = size / 2
            let centre = CGPoint(x: size / 2, y: size / 2)
            ZStack {
                Circle()
                    .fill(AngularGradient(
                        colors: stride(from: 0.0, through: 1.0, by: 1.0 / 12).map {
                            Color(hue: $0, saturation: 1, brightness: 1)
                        },
                        center: .center))
                Circle()
                    .fill(RadialGradient(colors: [.white, .white.opacity(0)], center: .center,
                                         startRadius: 0, endRadius: radius))
                // The picked point: a white ring with a thin dark edge, so it shows on any part of the wheel.
                Circle()
                    .fill(Color(hex: AlbumLightColour.hsvToHex(h: hue, s: saturation, v: 1)))
                    .frame(width: 26, height: 26)
                    .overlay(Circle().stroke(Color.white, lineWidth: 3))
                    .overlay(Circle().stroke(Color.black.opacity(0.35), lineWidth: 1).padding(-1.5))
                    .position(x: centre.x + cos(hue * 2 * .pi) * saturation * radius,
                              y: centre.y + sin(hue * 2 * .pi) * saturation * radius)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let dx = value.location.x - centre.x, dy = value.location.y - centre.y
                var angle = atan2(dy, dx) / (2 * .pi)
                if angle < 0 { angle += 1 }
                hue = angle >= 1 ? 0 : angle
                saturation = min(1, (dx * dx + dy * dy).squareRoot() / radius)
                changed()
            })
        }
        .accessibilityElement()
        .accessibilityLabel("Light colour wheel")
        .accessibilityValue("hue \(Int(hue * 360)) degrees, \(Int(saturation * 100)) percent colour")
        .accessibilityAdjustableAction { direction in
            hue = (hue + (direction == .increment ? 1.0 / 24 : -1.0 / 24) + 1).truncatingRemainder(dividingBy: 1)
            changed()
        }
    }
}
