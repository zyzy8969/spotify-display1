import SwiftUI
import UIKit
import CryptoKit

/// GIFs shown on the keychain lately, so they can be shown again and starred, like `PhotoLibrary`.
/// Starred GIFs can be the start-up picture (with starred photos). Newest first, at most `cap`;
/// unstarred ones are dropped first. GIPHY GIFs keep only their links (GIPHY's terms: no copies) and
/// download again when shown; GIFs made from your videos keep their frames here.
@MainActor
final class GifLibrary: ObservableObject {
    static let shared = GifLibrary()
    static let cap = 24

    struct Item: Codable, Identifiable, Equatable {
        /// "giphy-<id>", or the MD5 (hex) of a video GIF's frames, also its file name.
        let id: String
        var added: Date
        var favorite: Bool? = nil
        /// A GIPHY GIF (links only); nil = made from a video, frames saved here.
        var giphy: GiphyGIF? = nil
        /// Frames of a video GIF (to read its file back).
        var frameCount: Int? = nil

        var isFavorite: Bool { favorite ?? false }
    }

    @Published private(set) var items: [Item] = []

    var favorites: [Item] { items.filter(\.isFavorite) }

    private let directory: URL? = {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = base.appendingPathComponent("GifLibrary.v1", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var indexURL: URL? { directory?.appendingPathComponent("index.json") }

    private init() {
        if let url = indexURL, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([Item].self, from: data) {
            items = saved.filter { item in
                item.giphy != nil || (framesURL(for: item.id).map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
            }
        }
    }

    func framesURL(for id: String) -> URL? { directory?.appendingPathComponent(id + ".bin") }
    func posterURL(for id: String) -> URL? { directory?.appendingPathComponent(id + ".jpg") }

    /// A GIPHY GIF that was shown (or starred from search).
    @discardableResult
    func addGiphy(_ gif: GiphyGIF, favorite: Bool = false) -> Item {
        var item = Item(id: "giphy-" + gif.id, added: Date(), giphy: gif)
        if favorite { item.favorite = true }
        return insert(item)
    }

    /// A GIF made from a video that was shown: its frames are kept so it can be shown again.
    @discardableResult
    func addVideo(_ animation: KeychainAnimation) -> Item? {
        let raw = animation.rawPayload
        let id = Insecure.MD5.hash(data: raw).map { String(format: "%02x", $0) }.joined()
        guard let framesURL = framesURL(for: id), let posterURL = posterURL(for: id) else { return nil }
        if !FileManager.default.fileExists(atPath: framesURL.path) {
            guard (try? raw.write(to: framesURL, options: .atomic)) != nil else { return nil }
            try? animation.posterJPEG.write(to: posterURL, options: .atomic)
        }
        return insert(Item(id: id, added: Date(), frameCount: animation.count))
    }

    /// Shown again: to the front.
    func moveToFront(_ item: Item) {
        insert(item)
    }

    func toggleFavorite(_ item: Item) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].favorite = items[i].isFavorite ? nil : true
        saveIndex()
    }

    func remove(_ item: Item) {
        items.removeAll { $0.id == item.id }
        deleteFiles(of: item)
        saveIndex()
    }

    /// The GIF as the keychain plays it: a GIPHY one downloaded and converted, a video one read back.
    nonisolated func animation(for item: Item) async throws -> KeychainAnimation {
        if let giphy = item.giphy {
            let data = try await GiphyClient.download(giphy)
            guard let animation = AnimationPrep.fromGIF(data) else { throw SpotifyDisplayError.conversionFailed }
            return animation
        }
        let (framesURL, posterURL) = await MainActor.run { (self.framesURL(for: item.id), self.posterURL(for: item.id)) }
        guard let framesURL, let count = item.frameCount,
              let raw = try? Data(contentsOf: framesURL),
              let animation = KeychainAnimation(raw: raw, count: count,
                                                posterJPEG: posterURL.flatMap { try? Data(contentsOf: $0) } ?? Data())
        else { throw SpotifyDisplayError.conversionFailed }
        return animation
    }

    /// `item` at the front (keeping its star and the newest GIPHY links), then the cap.
    @discardableResult
    private func insert(_ item: Item) -> Item {
        var item = item
        if let i = items.firstIndex(where: { $0.id == item.id }) {
            let old = items.remove(at: i)
            item.favorite = (old.isFavorite || item.isFavorite) ? true : nil
            item.frameCount = item.frameCount ?? old.frameCount
        }
        item.added = Date()
        items.insert(item, at: 0)
        let (kept, dropped) = PhotoLibraryTrim.trimmed(items, cap: Self.cap, isFavorite: \.isFavorite)
        items = kept
        for gone in dropped { deleteFiles(of: gone) }
        saveIndex()
        return item
    }

    private func deleteFiles(of item: Item) {
        guard item.giphy == nil else { return }
        for url in [framesURL(for: item.id), posterURL(for: item.id)].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func saveIndex() {
        guard let url = indexURL, let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Over `cap`: drops the oldest unstarred items first; starred ones only once nothing else is left.
enum PhotoLibraryTrim {
    static func trimmed<T>(_ items: [T], cap: Int, isFavorite: (T) -> Bool) -> (kept: [T], dropped: [T]) {
        var kept = items
        var dropped: [T] = []
        while kept.count > cap {
            let i = kept.lastIndex(where: { !isFavorite($0) }) ?? kept.count - 1
            dropped.append(kept.remove(at: i))
        }
        return (kept, dropped)
    }
}

/// A recent / starred GIF's square: GIPHY ones play their preview, video ones show their first frame.
/// A star in the corner marks favourites.
struct SavedGifThumb: View {
    let item: GifLibrary.Item
    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            if let giphy = item.giphy {
                GifThumb(url: giphy.previewURL)
            } else {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        if let url = GifLibrary.shared.posterURL(for: item.id),
                           let image = UIImage(contentsOfFile: url.path) {
                            Image(uiImage: image).resizable()
                        } else {
                            theme.artSurface
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .overlay(alignment: .topTrailing) {
            if item.isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.yellow)
                    .padding(4)
                    .background(Circle().fill(.black.opacity(0.45)))
                    .padding(4)
                    .accessibilityHidden(true)
            }
        }
    }
}
