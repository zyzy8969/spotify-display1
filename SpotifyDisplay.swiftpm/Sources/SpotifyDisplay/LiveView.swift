import SwiftUI

/// Nerd mode's stats area under the Now Playing controls: live details and the terminal, then the
/// general transfer stats, all compacted. The caller provides the scrolling, the side margins and the
/// smaller text (`themeTextScale`).
struct NerdStatsView: View {
    @ObservedObject var bleManager: BLEManager
    @ObservedObject var spotifyManager: SpotifyManager

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LiveView(bleManager: bleManager, spotifyManager: spotifyManager, compact: true)
            ThemedDivider()
            GeneralStatsView(bleManager: bleManager, spotifyManager: spotifyManager, compact: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What the display is doing right now (phase, board and Spotify status) and a terminal-style log of
/// every event the app sends to or hears from the board. In-memory only: it starts empty each launch.
/// The last transition's name is no longer shown here: it is the sparkles icon in the header.
struct LiveView: View {
    @ObservedObject var bleManager: BLEManager
    @ObservedObject var spotifyManager: SpotifyManager
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 14 : 24) {
            LiveDetails(bleManager: bleManager, spotifyManager: spotifyManager)
            TerminalView(lines: bleManager.eventLog, height: compact ? 170 : 320)
        }
    }
}

/// Dark terminal pane. Newest line at the bottom; sticks to the bottom as lines arrive.
struct TerminalView: View {
    let lines: [LogLine]
    var height: CGFloat = 320
    @Environment(\.theme) private var theme

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Terminal")
                .themeText(.eyebrow)
                .foregroundStyle(theme.inkFaint)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        if lines.isEmpty {
                            Text("waiting for activity…")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(Color(white: 0.55))
                        }
                        ForEach(lines) { line in
                            Text("\(Self.timeFormatter.string(from: line.date)) \(line.text)")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(color(for: line.kind))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(10)
                }
                .frame(height: height)
                .background(Color(white: 0.07))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onChange(of: lines.count) { _ in
                    if let last = lines.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
                .onAppear {
                    if let last = lines.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .accessibilityLabel("Terminal log")
        }
        .textSelection(.enabled)
    }

    private func color(for kind: LogLine.Kind) -> Color {
        switch kind {
        case .info: return Color(white: 0.7)
        case .tx: return Color(red: 0.45, green: 0.8, blue: 1.0)
        case .rx: return Color(red: 0.55, green: 0.9, blue: 0.6)
        case .transition: return Color(red: 1.0, green: 0.8, blue: 0.35)
        case .error: return Color(red: 1.0, green: 0.45, blue: 0.4)
        }
    }
}
