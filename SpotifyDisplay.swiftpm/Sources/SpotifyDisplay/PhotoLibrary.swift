import SwiftUI
import PhotosUI
import UIKit
import CryptoKit

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
    }

    @Published private(set) var items: [Item] = []

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

    private func fileURL(for id: String) -> URL? {
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
        while items.count > Self.cap {
            let dropped = items.removeLast()
            if let url = fileURL(for: dropped.id) { try? FileManager.default.removeItem(at: url) }
        }
        saveIndex()
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
    @State private var pickedItem: PhotosPickerItem?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SheetHeader(title: "Photos") { dismiss() }
                PhotosPicker(selection: $pickedItem, matching: .images) {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                        Text("Add from your photos")
                            .themeText(.row)
                    }
                    .foregroundStyle(theme.ink)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(theme.ringOff, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Add a photo from your photo library")
                .onChange(of: pickedItem) { item in
                    guard let item else { return }
                    pickedItem = nil
                    onPicked(item)
                    dismiss()
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Saved")
                        .themeText(.eyebrow)
                        .foregroundStyle(theme.inkFaint)
                    Text(library.items.isEmpty
                         ? "Photos you show on the keychain are saved here, so you can show them again."
                         : "Tap one to show it again. They are on the keychain's card too, so they appear in about a second. Touch and hold to remove one from this list.")
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
                            Button(role: .destructive) {
                                library.remove(item)
                            } label: {
                                Label("Remove from saved", systemImage: "trash")
                            }
                        }
                        .accessibilityLabel("Saved photo from \(item.added.formatted(date: .abbreviated, time: .shortened))")
                        .accessibilityHint("Shows it on the display")
                    }
                }
            }
            .padding(.horizontal, theme.margin + 4)
            .padding(.bottom, 32)
        }
        .background(theme.background.ignoresSafeArea())
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
            .task(id: item.id) {
                guard image == nil, let jpeg = PhotoLibrary.shared.jpeg(for: item) else { return }
                image = await Task.detached(priority: .userInitiated) {
                    UIImage(data: jpeg)?.preparingThumbnail(of: CGSize(width: 240, height: 240))
                }.value
            }
    }
}
