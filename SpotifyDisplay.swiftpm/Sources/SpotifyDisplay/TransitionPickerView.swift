import SwiftUI

/// Chooses which transitions the board may use. Every row plays a looping example of its effect.
/// The choice is stored as the list of switched-off indices (`TransitionPrefs`) and sent to the
/// board as a bitmask (BLE_PROTOCOL 1.12), so it applies to cache hits and new songs alike.
struct TransitionPickerView: View {
    @ObservedObject var bleManager: BLEManager

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @AppStorage(TransitionPrefs.storageKey) private var disabledRaw = ""

    var body: some View {
        let enabled = TransitionPrefs.enabledCount(disabledRaw: disabledRaw)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                SheetHeader(title: "Transitions") { dismiss() }
                summary(enabled: enabled)
                    .padding(.top, 8)
                shortcuts
                    .padding(.top, 14)
                if !bleManager.boardSupportsTransitionMask && bleManager.isConnected {
                    Text("This display's firmware is older than BLE protocol 1.12, so it picks from every transition no matter what is switched on here. Flash the new firmware to use this list.")
                        .themeText(.footnote)
                        .foregroundStyle(theme.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 12)
                }
                ThemedDivider()
                    .padding(.vertical, 18)
                ForEach(TransitionCatalog.groups) { group in
                    groupHeader(group)
                    ForEach(group.ids, id: \.self) { tid in
                        if let info = TransitionCatalog.info(id: tid) {
                            row(info)
                                .padding(.bottom, 16)
                        }
                    }
                }
                Text("Previews are drawn by the display's own transition code, so they show the real effect; only their speed is estimated. New songs use quick transitions unless none of them is switched on.")
                    .themeText(.statCaption)
                    .foregroundStyle(theme.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            .padding(.horizontal, theme.margin + 4)
            .padding(.bottom, 32)
        }
        .background(theme.background.ignoresSafeArea())
        .onChange(of: disabledRaw) { _ in
            bleManager.applyTransitionPrefs()
        }
    }

    private func summary(enabled: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(enabled) of \(TransitionCatalog.all.count) switched on")
                .themeText(.row)
                .foregroundStyle(theme.ink)
            Text(enabled == 0
                 ? "None switched on: the display will use all of them."
                 : "The display picks one of the switched-on transitions at random each time the cover changes.")
                .themeText(.footnote)
                .foregroundStyle(theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var shortcuts: some View {
        HStack(spacing: 22) {
            shortcut("All on") { disabledRaw = "" }
            shortcut("All off") {
                disabledRaw = TransitionPrefs.raw(from: Set(TransitionCatalog.all.map(\.id)))
            }
            shortcut("Quick only") {
                disabledRaw = TransitionPrefs.raw(from: Set(TransitionCatalog.all.filter { !$0.quick }.map(\.id)))
            }
        }
    }

    private func shortcut(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .themeText(.rowValue)
                .foregroundStyle(theme.ink)
                .underline()
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Theme heading with a one-tap switch for the whole family: all on, or all off if they already are.
    private func groupHeader(_ group: TransitionCatalog.Group) -> some View {
        let off = TransitionPrefs.disabledSet(from: disabledRaw)
        let onCount = group.ids.filter { !off.contains($0) }.count
        let allOn = onCount == group.ids.count
        return HStack(alignment: .firstTextBaseline) {
            Text(group.name)
                .themeText(.eyebrow)
                .foregroundStyle(theme.inkFaint)
            Text("\(onCount)/\(group.ids.count)")
                .themeText(.statCaption)
                .foregroundStyle(theme.inkFaint)
            Spacer()
            Button {
                // "Only these": everything outside this group off, this group on.
                let outside = Set(TransitionCatalog.all.map(\.id)).subtracting(group.ids)
                disabledRaw = TransitionPrefs.raw(from: outside)
            } label: {
                Text("Only these")
                    .themeText(.rowValue)
                    .foregroundStyle(theme.ink)
                    .underline()
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                var next = off
                if allOn { group.ids.forEach { next.insert($0) } } else { group.ids.forEach { next.remove($0) } }
                disabledRaw = TransitionPrefs.raw(from: next)
            } label: {
                Text(allOn ? "All off" : "All on")
                    .themeText(.rowValue)
                    .foregroundStyle(theme.ink)
                    .underline()
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 10)
        .accessibilityElement(children: .combine)
    }

    private func isOn(_ info: TransitionInfo) -> Binding<Bool> {
        Binding(
            get: { !TransitionPrefs.disabledSet(from: disabledRaw).contains(info.id) },
            set: { on in
                var off = TransitionPrefs.disabledSet(from: disabledRaw)
                if on { off.remove(info.id) } else { off.insert(info.id) }
                disabledRaw = TransitionPrefs.raw(from: off)
            }
        )
    }

    private func row(_ info: TransitionInfo) -> some View {
        let on = isOn(info)
        return HStack(alignment: .center, spacing: 14) {
            LoopingTransitionPreview(id: info.id, duration: info.duration)
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .opacity(on.wrappedValue ? 1 : 0.35)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(info.name)
                        .themeText(.row)
                        .foregroundStyle(on.wrappedValue ? theme.ink : theme.inkFaint)
                    if info.quick {
                        Text("quick")
                            .themeText(.statCaption)
                            .foregroundStyle(theme.inkFaint)
                    }
                }
                Text(info.blurb)
                    .themeText(.footnote)
                    .foregroundStyle(theme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: on)
                .labelsHidden()
                .toggleStyle(ThemedToggleStyle())
                .frame(width: 60)
                .accessibilityLabel(info.name)
        }
        .accessibilityElement(children: .contain)
    }
}
