import SwiftUI

/// Nerd mode's area under the compact player. The live details and the cache history (last three
/// transfers) are pinned at the top and do not scroll; under them the session log (every BLE / transfer line since the app was opened,
/// `BLEManager.eventLog`, newest at the bottom) scrolls on its own. It follows new lines while the
/// person is at the bottom and stays put when they have scrolled up (a "newest" button takes them
/// back down). The caller provides the side margins and the smaller text (`themeTextScale`).
struct NerdLogView: View {
    @ObservedObject var bleManager: BLEManager
    @ObservedObject var spotifyManager: SpotifyManager

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The bottom of the list is on screen (set by the sentinel row's appear / disappear).
    @State private var atBottom = true
    /// The full cache history sheet (from the button beside "Cache history").
    @State private var showFullHistory = false

    private static let bottomID = "nerd-log-bottom"

    var body: some View {
        let lines = bleManager.eventLog
        VStack(alignment: .leading, spacing: 0) {
            LiveDetails(bleManager: bleManager, spotifyManager: spotifyManager)
                .padding(.top, 8)
            ThemedDivider()
                .padding(.vertical, 8)
            CacheHistory(entries: bleManager.transferLog) {
                showFullHistory = true
            }
            ThemedDivider()
                .padding(.vertical, 8)
            Text(theme.id.text(.sessionLog))
                .themeText(.eyebrow)
                .foregroundStyle(theme.inkFaint)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 8)
            log(lines)
        }
        .sheet(isPresented: $showFullHistory) {
            FullCacheHistoryView(bleManager: bleManager)
                .environment(\.theme, theme)
                .preferredColorScheme(theme.colorScheme)
        }
    }

    private func log(_ lines: [LogLine]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if lines.isEmpty {
                        Text(theme.id.text(.waitingForActivity))
                            .themeText(.mono)
                            .foregroundStyle(theme.inkFaint)
                    }
                    ForEach(lines) { line in
                        SessionLogRow(line: line)
                            .id(line.id)
                    }
                    Color.clear
                        .frame(height: 16)
                        .id(Self.bottomID)
                        .onAppear { atBottom = true }
                        .onDisappear { atBottom = false }
                }
                .textSelection(.enabled)
            }
            .overlay(alignment: .bottomTrailing) {
                if !atBottom && !lines.isEmpty {
                    newestButton(proxy)
                        .transition(.opacity)
                }
            }
            .onChange(of: lines.last?.id) { _ in
                guard atBottom else { return }
                if reduceMotion {
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                } else {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(Self.bottomID, anchor: .bottom)
                    }
                }
            }
            .onAppear {
                // Next turn: the lazy rows need one layout pass before they can be scrolled to.
                DispatchQueue.main.async {
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
            }
        }
    }

    private func newestButton(_ proxy: ScrollViewProxy) -> some View {
        Button {
            atBottom = true
            if reduceMotion {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            } else {
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(Self.bottomID, anchor: .bottom)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 11, weight: .semibold))
                Text(theme.id.text(.newestLine))
                    .themeText(.footnote)
                    .lineLimit(1)
            }
            .foregroundStyle(theme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(theme.background))
            .overlay(Capsule().stroke(theme.ringOff, lineWidth: 1))
            .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 2)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.bottom, 6)
        .accessibilityLabel("Scroll to the newest log line")
    }
}

/// One session-log line in the Live details style: time on the left (faint), the event on the right,
/// and a small shape-coded marker for sends (ring), replies (dot), transitions and errors. The line's
/// own text says "tx" / "rx" / "error" too, so nothing relies on colour alone.
struct SessionLogRow: View {
    let line: LogLine
    @Environment(\.theme) private var theme
    @ScaledMetric(relativeTo: .caption2) private var markerSize: CGFloat = 6

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.timeFormatter.string(from: line.date))
                .themeText(.mono)
                .foregroundStyle(theme.inkFaint)
            marker
                .frame(width: markerSize, height: markerSize)
                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] }
            Text(line.text)
                .themeText(.mono)
                .foregroundStyle(line.kind == .error ? theme.destructive : theme.inkSoft)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var marker: some View {
        switch line.kind {
        case .info:
            Color.clear
        case .tx:
            StateMarker(filled: false, fillColor: theme.display, ringColor: theme.display, size: markerSize)
        case .rx:
            StateMarker(filled: true, fillColor: theme.display, ringColor: theme.display, size: markerSize)
        case .transition:
            StateMarker(filled: true, fillColor: theme.accent, ringColor: theme.accent, size: markerSize)
        case .error:
            StateMarker(filled: true, fillColor: theme.destructive, ringColor: theme.destructive, size: markerSize)
        }
    }
}

// MARK: - Live details

/// What the display is doing right now, plus a few short values from this session's transfers (the
/// history and totals are in Settings > Lifetime stats). Label / value rows; values in monospace.
struct LiveDetails: View {
    @ObservedObject var bleManager: BLEManager
    @ObservedObject var spotifyManager: SpotifyManager
    @Environment(\.theme) private var theme
    /// Label column; values start after it, well clear of the labels.
    @ScaledMetric(relativeTo: .caption2) private var labelWidth: CGFloat = 76

    private struct Row: Identifiable {
        let id: String
        let label: String
        let value: String
        var isError = false
    }

    private static let none = "\u{2014}"

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(theme.id.text(.liveDetails))
                .themeText(.eyebrow)
                .foregroundStyle(theme.inkFaint)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 4)
            ForEach(rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(row.label)
                        .themeText(.mono)
                        .foregroundStyle(theme.inkFaint)
                        .frame(width: labelWidth, alignment: .leading)
                    // One line each, so the block never changes height (it is pinned above the log).
                    Text(row.value)
                        .themeText(.mono)
                        .monospacedDigit()
                        .foregroundStyle(row.isError ? theme.destructive : theme.inkSoft)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.leading, 8)
    }

    /// The same ten rows every time (a dash when there is nothing yet), so the block keeps one size.
    private var rows: [Row] {
        let entries = bleManager.transferLog
        let hits = entries.filter { $0.cacheHit }.count
        let error = spotifyManager.lastError.flatMap { $0.isEmpty ? nil : $0 }
        return [
            Row(id: "live", label: "live", value: bleManager.currentLivePhase ?? "idle"),
            Row(id: "board", label: "board", value: bleManager.statusMessage),
            Row(
                id: "progress",
                label: "progress",
                value: bleManager.isTransferring ? "\(Int((bleManager.transferProgress * 100).rounded()))%" : Self.none
            ),
            Row(id: "ack", label: "ack", value: bleManager.boardAckStatus ?? Self.none),
            Row(id: "last", label: "last", value: bleManager.lastTransferResult ?? Self.none),
            // A Spotify error takes this row's place (in red) rather than adding a row.
            Row(
                id: "spotify",
                label: error == nil ? "spotify" : "error",
                value: error ?? spotifyManager.pollStatus ?? Self.none,
                isError: error != nil
            ),
            Row(id: "sd", label: "on sd", value: bleManager.sdCacheEntryCount.map { "\($0) covers" } ?? Self.none),
            Row(id: "hits", label: "hits", value: entries.isEmpty ? Self.none : "\(hits) of \(entries.count) cached"),
            Row(
                id: "avgHit",
                label: "avg hit",
                value: SessionStats.averageMs(entries, cacheHit: true).map { StatsFormat.short($0) } ?? Self.none
            ),
            Row(
                id: "avgNew",
                label: "avg new",
                value: SessionStats.averageMs(entries, cacheHit: false).map { StatsFormat.short($0) } ?? Self.none
            )
        ]
    }
}

/// Small read-only helpers over `BLEManager.transferLog` (in memory, last 30 transfers).
enum SessionStats {
    static func averageMs(_ entries: [TransferLogEntry], cacheHit: Bool) -> Int? {
        let matching = entries.filter { $0.cacheHit == cacheHit }
        guard !matching.isEmpty else { return nil }
        return matching.reduce(0) { $0 + $1.totalMs } / matching.count
    }

    /// Whole-number percentage of cache hits, nil with no transfers.
    static func hitRatePercent(_ entries: [TransferLogEntry]) -> Int? {
        guard !entries.isEmpty else { return nil }
        let hits = entries.filter { $0.cacheHit }.count
        return Int((Double(hits) / Double(entries.count) * 100).rounded())
    }
}
