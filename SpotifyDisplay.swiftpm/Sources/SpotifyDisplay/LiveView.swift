import SwiftUI

/// The "Live" page of the main screen: what the display is doing right now (the transition it just
/// drew, current phase, board and Spotify status) and a terminal-style log of every event the app sends
/// to or hears from the board. In-memory only: it starts empty each launch.
struct LiveView: View {
    @ObservedObject var bleManager: BLEManager
    @ObservedObject var spotifyManager: SpotifyManager
    let onOpen: (Panel) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            transitionCard
            LiveDetails(bleManager: bleManager, spotifyManager: spotifyManager)
            TerminalView(lines: bleManager.eventLog)
        }
    }

    private var transitionCard: some View {
        let name = bleManager.lastTransitionName
        let info = name.flatMap { TransitionCatalog.info(named: $0) }
        return VStack(alignment: .leading, spacing: 10) {
            Text("Last transition")
                .themeText(.eyebrow)
                .foregroundStyle(theme.inkFaint)
            HStack(alignment: .center, spacing: 16) {
                if let info {
                    LoopingTransitionPreview(id: info.id, duration: info.duration)
                        .frame(width: 84, height: 84)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(name ?? "None yet")
                        .themeText(.statNumber)
                        .foregroundStyle(theme.ink)
                        .lineLimit(2)
                    if let info {
                        Text(info.blurb)
                            .themeText(.footnote)
                            .foregroundStyle(theme.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Shows up after the display draws the next cover.")
                            .themeText(.footnote)
                            .foregroundStyle(theme.inkSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button { onOpen(.transitions) } label: {
                        Text("Choose transitions")
                            .themeText(.rowValue)
                            .foregroundStyle(theme.ink)
                            .underline()
                            .frame(minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Dark terminal pane. Newest line at the bottom; sticks to the bottom as lines arrive.
struct TerminalView: View {
    let lines: [LogLine]
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
                .frame(height: 320)
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
