import SwiftUI
import PhotosUI
import UIKit
import CryptoKit
import ImageIO

/// Photos the person has shown on the keychain, saved on the phone so they can be shown again from the
/// Photos page. Each is kept as the exact square JPEG that was sent: the board saves a photo on its card
/// under the hash of those bytes (BLE_PROTOCOL 1.18), so showing a saved one again is a cache hit drawn
/// from the card in about a second. Newest first, at most `cap`. Removing one only removes it here.
@MainActor
final class PhotoLibrary: ObservableObject {
    static let shared = PhotoLibrary()
    static let cap = 60

    struct Item: Codable, Identifiable, Equatable {
        /// MD5 of the JPEG bytes (hex), also the file name.
        let id: String
        var added: Date
        /// Starred: one of these is shown when the keychain connects with nothing playing (the
        /// "Start-up picture" setting). Optional so an index.json saved before stars still decodes.
        var favorite: Bool? = nil

        var isFavorite: Bool { favorite ?? false }
    }

    @Published private(set) var items: [Item] = []

    /// The starred photos, newest first.
    var favorites: [Item] { items.filter(\.isFavorite) }

    private let directory: URL? = {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = base.appendingPathComponent("PhotoLibrary.v1", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var indexURL: URL? { directory?.appendingPathComponent("index.json") }

    private init() {
        if let url = indexURL, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([Item].self, from: data) {
            items = saved.filter { fileURL(for: $0.id).map { FileManager.default.fileExists(atPath: $0.path) } ?? false }
        }
    }

    func fileURL(for id: String) -> URL? {
        directory?.appendingPathComponent(id + ".jpg")
    }

    /// Saves `jpeg` (or moves it to the front if it is already saved).
    func add(_ jpeg: Data) {
        let id = jpeg.md5Hex
        if let i = items.firstIndex(where: { $0.id == id }) {
            var item = items.remove(at: i)
            item.added = Date()
            items.insert(item, at: 0)
        } else {
            guard let url = fileURL(for: id) else { return }
            try? jpeg.write(to: url, options: .atomic)
            items.insert(Item(id: id, added: Date()), at: 0)
        }
        let (kept, dropped) = Self.trimmed(items, cap: Self.cap)
        items = kept
        for gone in dropped {
            if let url = fileURL(for: gone.id) { try? FileManager.default.removeItem(at: url) }
        }
        saveIndex()
    }

    /// Over `cap`: drops the oldest unstarred photos first; starred ones only once nothing else is left.
    nonisolated static func trimmed(_ items: [Item], cap: Int) -> (kept: [Item], dropped: [Item]) {
        var kept = items
        var dropped: [Item] = []
        while kept.count > cap {
            let i = kept.lastIndex(where: { !$0.isFavorite }) ?? kept.count - 1
            dropped.append(kept.remove(at: i))
        }
        return (kept, dropped)
    }

    func toggleFavorite(_ item: Item) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].favorite = items[i].isFavorite ? nil : true
        saveIndex()
    }

    // MARK: Start-up picture

    /// UserDefaults key of the "Start-up picture" setting (Settings, Keychain section).
    nonisolated static let startupPictureKey = "startupPicture"
    /// The starred photo shown at the last connect, so the next connect picks a different one.
    private static let lastStartupKey = "startupPicture.lastId"

    /// A random starred photo's JPEG for the start-up picture, never the one shown last time when
    /// there are two or more. Nil with no stars.
    func nextStartupJPEG() -> Data? {
        var candidates = favorites.map(\.id)
        let defaults = UserDefaults.standard
        var rng = SystemRandomNumberGenerator()
        while let id = Self.pickStartup(from: candidates, last: defaults.string(forKey: Self.lastStartupKey), using: &rng) {
            if let url = fileURL(for: id), let jpeg = try? Data(contentsOf: url) {
                defaults.set(id, forKey: Self.lastStartupKey)
                return jpeg
            }
            candidates.removeAll { $0 == id }  // file missing: try another
        }
        return nil
    }

    /// Random pick from `ids`, skipping `last` unless it is the only one.
    nonisolated static func pickStartup<R: RandomNumberGenerator>(from ids: [String], last: String?,
                                                                   using rng: inout R) -> String? {
        let others = ids.filter { $0 != last }
        return (others.isEmpty ? ids : others).randomElement(using: &rng)
    }

    /// The saved JPEG, unchanged.
    func jpeg(for item: Item) -> Data? {
        fileURL(for: item.id).flatMap { try? Data(contentsOf: $0) }
    }

    func remove(_ item: Item) {
        items.removeAll { $0.id == item.id }
        if let url = fileURL(for: item.id) { try? FileManager.default.removeItem(at: url) }
        saveIndex()
    }

    private func saveIndex() {
        guard let url = indexURL, let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

private extension Data {
    /// File name for a saved photo (not a security use).
    var md5Hex: String {
        Insecure.MD5.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}

/// The Photos page (header photo icon): add a photo from the phone, or pick one already shown before.
struct PhotoLibraryView: View {
    /// A new photo picked from the phone's library.
    let onPicked: (PhotosPickerItem) -> Void
    /// A saved photo chosen (its exact JPEG).
    let onChoose: (Data) -> Void

    @ObservedObject private var library = PhotoLibrary.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var pickedItems: [PhotosPickerItem] = []
    /// Photos still being read and saved after a multi-pick (shown under the add button).
    @State private var adding = 0
    @State private var addFailed = 0

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SheetHeader(title: "Photos") { dismiss() }
                // Several at once go straight into Saved; a single pick is shown on the keychain.
                // `.current`: the photo as stored (often HEIC), not transcoded to JPEG first, which was
                // the slow part of loading one; ImageIO reads HEIC directly.
                PhotosPicker(selection: $pickedItems, maxSelectionCount: 30, selectionBehavior: .ordered,
                             matching: .images, preferredItemEncoding: .current) {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Add from your photos")
                            .themeText(.row)
                        Text("one or more")
                            .themeText(.statCaption)
                            .foregroundStyle(theme.inkFaint)
                    }
                    .foregroundStyle(theme.ink)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(theme.ringOff, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Add photos from your photo library")
                .accessibilityHint("Pick one to show it on the display, or several to save them all here")
                .onChange(of: pickedItems) { items in
                    guard !items.isEmpty else { return }
                    pickedItems = []
                    if items.count == 1 {
                        onPicked(items[0])
                        dismiss()
                    } else {
                        addAll(items)
                    }
                }

                if adding > 0 || addFailed > 0 {
                    HStack(spacing: 8) {
                        if adding > 0 { ProgressView().controlSize(.small) }
                        Text(addingStatus)
                            .themeText(.footnote)
                            .foregroundStyle(theme.inkSoft)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Saved")
                        .themeText(.eyebrow)
                        .foregroundStyle(theme.inkFaint)
                    Text(library.items.isEmpty
                         ? "Photos you show on the keychain are saved here, so you can show them again."
                         : "Tap one to show it again. They are on the keychain's card too, so they appear in about a second. Touch and hold to star one or remove it from this list. With Start-up picture on in Settings, a starred photo shows when the keychain connects and nothing is playing.")
                        .themeText(.footnote)
                        .foregroundStyle(theme.inkSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }

                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(library.items) { item in
                        Button {
                            guard let jpeg = library.jpeg(for: item) else { return }
                            onChoose(jpeg)
                            dismiss()
                        } label: {
                            PhotoThumb(item: item)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                library.toggleFavorite(item)
                            } label: {
                                Label(item.isFavorite ? "Unstar" : "Star for start-up",
                                      systemImage: item.isFavorite ? "star.slash" : "star")
                            }
                            Button(role: .destructive) {
                                library.remove(item)
                            } label: {
                                Label("Remove from saved", systemImage: "trash")
                            }
                        }
                        .accessibilityLabel("\(item.isFavorite ? "Starred photo" : "Saved photo") from \(item.added.formatted(date: .abbreviated, time: .shortened))")
                        .accessibilityHint("Shows it on the display")
                    }
                }
            }
            .padding(.horizontal, theme.margin + 4)
            .padding(.bottom, 32)
        }
        .background(theme.background.ignoresSafeArea())
    }

    private var addingStatus: String {
        var parts: [String] = []
        if adding > 0 { parts.append("Adding \(adding) photo\(adding == 1 ? "" : "s")\u{2026}") }
        if addFailed > 0 { parts.append("\(addFailed) couldn\u{2019}t be read.") }
        return parts.joined(separator: " ")
    }

    /// Reads and squares every picked photo in parallel (off the main thread), then saves them in the
    /// order picked: the first one picked ends up at the top. Nothing is sent to the keychain.
    private func addAll(_ items: [PhotosPickerItem]) {
        adding += items.count
        addFailed = 0
        Task {
            var jpegs = [Data?](repeating: nil, count: items.count)
            await withTaskGroup(of: (Int, Data?).self) { group in
                for (i, item) in items.enumerated() {
                    group.addTask {
                        guard let data = try? await item.loadTransferable(type: Data.self) else { return (i, nil) }
                        return (i, PhotoPrep.squareJPEG(fromPhotoData: data))
                    }
                }
                for await (i, jpeg) in group {
                    jpegs[i] = jpeg
                }
            }
            adding = max(0, adding - items.count)
            // `add` puts each at the front, so add the last-picked first.
            for jpeg in jpegs.reversed() {
                if let jpeg { library.add(jpeg) } else { addFailed += 1 }
            }
        }
    }
}

/// A saved photo's square thumbnail, decoded off the main thread.
private struct PhotoThumb: View {
    let item: PhotoLibrary.Item
    @State private var image: UIImage?
    @Environment(\.theme) private var theme

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    theme.artSurface
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if item.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.yellow)
                        .padding(5)
                        .background(Circle().fill(Color.black.opacity(0.45)))
                        .padding(5)
                        .accessibilityHidden(true)
                }
            }
            .task(id: item.id) {
                guard image == nil else { return }
                let key = item.id as NSString
                if let cached = Self.cache.object(forKey: key) {
                    image = cached
                    return
                }
                // File read and decode both off the main thread (the read used to run on it).
                guard let url = PhotoLibrary.shared.fileURL(for: item.id) else { return }
                let thumb = await Task.detached(priority: .userInitiated) {
                    PhotoThumb.thumbnail(at: url)
                }.value
                if let thumb { Self.cache.setObject(thumb, forKey: key) }
                image = thumb
            }
    }

    /// Decoded thumbnails, so reopening the Photos page shows them at once.
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = PhotoLibrary.cap
        return c
    }()

    /// ImageIO straight to a small image, without decoding the full 480x480 JPEG first.
    nonisolated static func thumbnail(at url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 240,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options).map { UIImage(cgImage: $0) }
    }
}
