import SwiftUI

/// Settings > Lifetime stats: a sheet with the general transfer stats.
struct LifetimeStatsView: View {
    @ObservedObject var bleManager: BLEManager
    @ObservedObject var spotifyManager: SpotifyManager

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                SheetHeader(title: theme.id.text(.lifetimeStats)) { dismiss() }
                AllTimeStats(bleManager: bleManager)
                ThemedDivider()
                LastTimeStats(entry: bleManager.lifetime.last)
            }
            .padding(.horizontal, theme.margin + 4)
            .padding(.bottom, 32)
        }
        .background(theme.background.ignoresSafeArea())
    }
}

/// All-time totals saved on the phone (`BLEManager.lifetime`), above this launch's details.
struct AllTimeStats: View {
    @ObservedObject var bleManager: BLEManager
    @Environment(\.theme) private var theme
    @State private var confirmReset = false

    var body: some View {
        let s = bleManager.lifetime
        VStack(alignment: .leading, spacing: 12) {
            Text("All time")
                .themeText(.eyebrow)
                .foregroundStyle(theme.inkFaint)
            if s.covers == 0 && s.photos == 0 {
                Text("Nothing yet. Covers you play are counted here from now on.")
                    .themeText(.footnote)
                    .foregroundStyle(theme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                row("Covers shown", "\(s.covers)")
                row("From the SD card", cachedText(s))
                row("Sent new", "\(s.freshCovers)")
                if s.photos > 0 { row("Photos shown", "\(s.photos)") }
                if let ms = s.averageCachedMs { row("Average cached", theme.id.seconds(ms)) }
                if let ms = s.averageFreshMs { row("Average new", theme.id.seconds(ms)) }
                if let ms = s.fastestFreshMs { row("Fastest new", theme.id.seconds(ms)) }
                if let fav = s.favouriteTransition { row("Most drawn transition", "\(fav.name) ×\(fav.count)") }
                if let first = s.firstRecorded {
                    row("Counting since", first.formatted(date: .abbreviated, time: .omitted))
                }
                Button {
                    confirmReset = true
                } label: {
                    Text("Reset all-time stats")
                        .themeText(.rowValue)
                        .foregroundStyle(theme.inkSoft)
                        .underline()
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .confirmationDialog("Reset all-time stats?", isPresented: $confirmReset, titleVisibility: .visible) {
                    Button("Reset", role: .destructive) { bleManager.resetLifetimeStats() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This clears the totals saved on this phone. Covers on the display are not affected.")
                }
            }
        }
    }

    private func cachedText(_ s: LifetimeStats) -> String {
        guard let rate = s.hitRate else { return "\(s.cachedCovers)" }
        return "\(s.cachedCovers)  (\(Int((rate * 100).rounded()))%)"
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .themeText(.row)
                .foregroundStyle(theme.ink)
            Spacer(minLength: 8)
            Text(value)
                .themeText(.rowValue)
                .foregroundStyle(theme.inkSoft)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Settings > Lifetime stats, under the totals: the most recent cover (saved with the totals, so it
/// is there after a relaunch too) with its time split per phase. The per-transfer cache history is in
/// nerd mode (`CacheHistory`).
struct LastTimeStats: View {
    let entry: TransferLogEntry?
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(theme.id.text(.lastTime))
                .themeText(.eyebrow)
                .foregroundStyle(theme.inkFaint)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 12)
            if let entry {
                LastTransferHero(entry: entry)
                Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                    .themeText(.statCaption)
                    .foregroundStyle(theme.inkFaint)
                    .padding(.top, 6)
                PhaseBreakdown(entry: entry)
                    .padding(.top, 24)
            } else {
                Text(theme.id.text(.nothingYet))
                    .themeText(.row)
                    .foregroundStyle(theme.inkSoft)
            }
        }
    }
}

/// Nerd mode: the last few transfers since the app was opened, each marked cached (filled dot) or
/// sent fresh (ring), with its phase timings.
struct CacheHistory: View {
    let entries: [TransferLogEntry]
    var limit = 3
    /// Opens the full history; nil hides the button.
    var onExpand: (() -> Void)? = nil
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Text(theme.id.text(.cacheHistory))
                    .themeText(.eyebrow)
                    .foregroundStyle(theme.inkFaint)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if let onExpand, !entries.isEmpty {
                    Button(action: onExpand) {
                        HStack(spacing: 4) {
                            Text(theme.id.text(.seeAll))
                                .themeText(.footnote)
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(theme.headerLink)
                        // Small label, full 44 pt target (it sits on the eyebrow line).
                        .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                        .padding(.vertical, -14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("See the full cache history")
                }
            }
            if entries.isEmpty {
                Text(theme.id.text(.nothingYet))
                    .themeText(.mono)
                    .foregroundStyle(theme.inkFaint)
            } else {
                RecentTransfers(entries: Array(entries.suffix(limit).reversed()), spacing: 6)
            }
        }
    }
}

/// Nerd mode > Cache history > See all: every transfer since the app was opened, newest first.
struct FullCacheHistoryView: View {
    @ObservedObject var bleManager: BLEManager
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        let entries = bleManager.transferLog
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SheetHeader(title: theme.id.text(.cacheHistory)) { dismiss() }
                if entries.isEmpty {
                    Text(theme.id.text(.nothingYet))
                        .themeText(.row)
                        .foregroundStyle(theme.inkSoft)
                } else {
                    MarkerLegend()
                    RecentTransfers(entries: Array(entries.reversed()))
                }
                Text("\(theme.id.text(.sinceOpened)) \u{00B7} last \(entries.count)")
                    .themeText(.statCaption)
                    .foregroundStyle(theme.inkFaint)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, theme.margin + 4)
            .padding(.bottom, 32)
        }
        .background(theme.background.ignoresSafeArea())
    }
}

// MARK: - Hero

struct LastTransferHero: View {
    let entry: TransferLogEntry
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if theme.heroLabelAbove { eyebrow }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(theme.id.seconds(entry.totalMs))
                    .themeText(.statBig)
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                HStack(spacing: 8) {
                    StateMarker(
                        filled: entry.cacheHit,
                        fillColor: theme.display,
                        ringColor: theme.fresh,
                        size: 12
                    )
                    Text(theme.id.heroUnit(cacheHit: entry.cacheHit))
                        .themeText(.statUnit)
                        .foregroundStyle(theme.inkSoft)
                }
            }
            if !theme.heroLabelAbove { eyebrow }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Last transfer, \(entry.cacheHit ? "cached" : "sent fresh"), \(StatsFormat.spoken(entry.totalMs)) seconds"
        )
    }

    private var eyebrow: some View {
        Text(theme.id.text(.lastTransfer))
            .themeText(.eyebrow)
            .foregroundStyle(theme.inkFaint)
    }
}

// MARK: - Phase breakdown

struct PhaseRow: Identifiable {
    let id: Int
    let name: String
    let ms: Int
    let color: Color
}

/// Where the time went for the last transfer. Bars for Crayon/Quiet, dot leaders for Serif.
struct PhaseBreakdown: View {
    let entry: TransferLogEntry
    @Environment(\.theme) private var theme

    var body: some View {
        let rows = makeRows()
        let slowest = max(1, rows.map(\.ms).max() ?? 1)
        VStack(alignment: .leading, spacing: theme.statsStyle == .dotLeaders ? 15 : 16) {
            ForEach(rows) { row in
                if theme.statsStyle == .dotLeaders {
                    LeaderPhaseRow(row: row, isSlowest: row.ms == slowest)
                } else {
                    BarPhaseRow(row: row, fraction: CGFloat(row.ms) / CGFloat(slowest))
                }
            }
        }
    }

    private func makeRows() -> [PhaseRow] {
        var rows: [PhaseRow] = []
        let colors = theme.phaseColors
        func add(_ index: Int, _ key: CopyKey, _ ms: Int?) {
            guard let ms, ms > 0 else { return }
            rows.append(PhaseRow(id: index, name: theme.id.text(key), ms: ms, color: Theme.pick(colors, index)))
        }
        add(0, .phaseLookup, entry.cacheCheckMs)
        add(1, .phaseDownload, entry.downloadMs)
        add(2, .phaseConvert, entry.convertMs)
        add(3, .phaseSend, entry.uploadMs)
        // Time not covered by a recorded phase (e.g. waiting for the display to confirm a cache
        // render). Download runs alongside the cache lookup, so it already covers that time.
        let covered = entry.cacheHit
            ? entry.cacheCheckMs
            : (entry.downloadMs ?? entry.cacheCheckMs) + (entry.convertMs ?? 0) + (entry.uploadMs ?? 0)
        let other = entry.totalMs - covered
        if other > 50 {
            add(4, .phaseOther, other)
        }
        return rows
    }
}

struct BarPhaseRow: View {
    let row: PhaseRow
    let fraction: CGFloat
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.name)
                    .themeText(.phaseName)
                    .foregroundStyle(theme.isWobbly ? theme.ink : theme.inkSoft)
                Spacer()
                Text(theme.id.seconds(row.ms))
                    .themeText(.phaseValue)
                    .foregroundStyle(theme.ink)
            }
            bar
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.name), \(StatsFormat.spoken(row.ms)) seconds")
    }

    @ViewBuilder
    private var bar: some View {
        let share = max(0.03, min(1, fraction))
        if theme.statsStyle == .crayonBars {
            ThemedStroke(
                shape: WobbleLine(amplitude: theme.wobble, bow: 0, seed: UInt64(row.id) + 120, inset: 4)
                    .trim(from: 0, to: share),
                color: row.color,
                lineWidth: 8
            )
            .frame(height: 12)
        } else {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.rule)
                    Capsule().fill(row.color).frame(width: geo.size.width * share)
                }
            }
            .frame(height: 3)
        }
    }
}

struct LeaderPhaseRow: View {
    let row: PhaseRow
    /// Serif's single rust accent marks the slowest step.
    let isSlowest: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(row.name)
                .themeText(.phaseName)
            DotLeader()
            Text(theme.id.seconds(row.ms))
                .themeText(.phaseValue)
        }
        .foregroundStyle(isSlowest ? theme.accent : theme.ink)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(row.name), \(StatsFormat.spoken(row.ms)) seconds\(isSlowest ? ", slowest step" : "")")
    }
}

struct DotLeader: View {
    @Environment(\.theme) private var theme

    var body: some View {
        WobbleLine()
            .stroke(theme.toggleOff, style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1, 3]))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .alignmentGuide(.firstTextBaseline) { d in d[.bottom] + 4 }
            .accessibilityHidden(true)
    }
}

// MARK: - Averages

struct AveragesRow: View {
    let entries: [TransferLogEntry]
    let cachedCount: Int?
    @Environment(\.theme) private var theme

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 30) {
                cells
            }
            VStack(alignment: .leading, spacing: 14) {
                cells
            }
        }
    }

    @ViewBuilder
    private var cells: some View {
        StatCell(value: average(cacheHit: true), label: theme.id.text(.avgCached))
        StatCell(value: average(cacheHit: false), label: theme.id.text(.avgNew))
        StatCell(value: cachedCount.map { "\($0)" } ?? "\u{2014}", label: theme.id.text(.savedLabel))
    }

    private func average(cacheHit: Bool) -> String {
        let matching = entries.filter { $0.cacheHit == cacheHit }
        guard !matching.isEmpty else { return "\u{2014}" }
        let total = matching.reduce(0) { $0 + $1.totalMs }
        return theme.id.seconds(total / matching.count)
    }
}

struct StatCell: View {
    let value: String
    let label: String
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .themeText(.statNumber)
                .foregroundStyle(theme.ink)
                .lineLimit(1)
            Text(label)
                .themeText(.statCaption)
                .foregroundStyle(theme.inkFaint)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Recent transfers

struct RecentTransfers: View {
    let entries: [TransferLogEntry]
    var spacing: CGFloat = 12

    private static let timeFormatter: DateFormatter = {
        // Follows the person's 12/24-hour setting and locale.
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(entries) { entry in
                TransferRow(entry: entry, time: Self.timeFormatter.string(from: entry.timestamp))
            }
        }
    }
}

struct TransferRow: View {
    let entry: TransferLogEntry
    let time: String
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 12) {
                StateMarker(filled: entry.cacheHit, fillColor: theme.display, ringColor: theme.fresh, size: 10)
                Text(time)
                    .themeText(.phaseName)
                    .foregroundStyle(theme.ink)
                Text(theme.id.text(entry.cacheHit ? .cachedWord : .freshWord))
                    .themeText(.phaseName)
                    .foregroundStyle(theme.inkSoft)
                Spacer(minLength: 8)
                Text(theme.id.seconds(entry.totalMs))
                    .themeText(.phaseValue)
                    .foregroundStyle(theme.inkSoft)
            }
            Text(detail)
                .themeText(.mono)
                .foregroundStyle(theme.inkFaint)
                .padding(.leading, 22)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(entry.cacheHit ? "Cached" : "Sent fresh") at \(time), \(StatsFormat.spoken(entry.totalMs)) seconds"
        )
    }

    /// The per-phase line the old inline debug strip showed.
    private var detail: String {
        var parts: [String] = []
        if entry.cacheHit {
            parts.append("cache \(StatsFormat.short(entry.cacheCheckMs))")
        } else {
            if entry.outcome == "photo" { parts.append("photo") }
            if let dl = entry.downloadMs { parts.append("dl \(StatsFormat.short(dl))") }
            if let cv = entry.convertMs { parts.append("cv \(StatsFormat.short(cv))") }
            if let ul = entry.uploadMs { parts.append("ble \(StatsFormat.short(ul))") }
        }
        // Since BLE_PROTOCOL 1.12 fresh sends report their transition too, not only cache hits.
        if let name = entry.transitionName, !name.isEmpty { parts.append("tr \(name)") }
        return parts.joined(separator: "  ")
    }
}

/// Filled dot = cached, hollow ring = sent fresh. Spelled out so the shapes never rely on colour.
struct MarkerLegend: View {
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 18) {
            item(filled: true, color: theme.display, text: theme.id.text(.cachedWord))
            item(filled: false, color: theme.fresh, text: theme.id.text(.freshWord))
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Filled dot means cached, hollow ring means sent fresh")
    }

    private func item(filled: Bool, color: Color, text: String) -> some View {
        HStack(spacing: 7) {
            StateMarker(filled: filled, fillColor: color, ringColor: color, size: 9)
            Text(text)
                .themeText(.statCaption)
                .foregroundStyle(theme.inkFaint)
        }
    }
}

enum StatsFormat {
    static func short(_ ms: Int) -> String {
        String(format: "%.1fs", Double(ms) / 1000.0)
    }

    static func spoken(_ ms: Int) -> String {
        String(format: "%.1f", Double(ms) / 1000.0)
    }
}
