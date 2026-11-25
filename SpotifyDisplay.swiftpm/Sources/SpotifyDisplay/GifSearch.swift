import SwiftUI
import UIKit
import ImageIO
import CoreTransferable
import UniformTypeIdentifiers

// MARK: - GIPHY

/// One GIPHY result. Nothing from GIPHY is stored on the phone: GIPHY's terms say apps must not keep
/// copies of their media, and the GIFs tab is search-and-show only (owner, 2026-11-24).
struct GiphyGIF: Identifiable, Equatable {
    let id: String
    let title: String
    /// `fixed_width` (200 px wide GIF): what is sent to the keychain (120 px frames).
    let sendURL: URL
    /// `fixed_width_small` (100 px wide GIF): the grid preview.
    let previewURL: URL
}

/// What the GIFs tab hands back: a GIPHY GIF to download and show, or a video clip already converted.
enum GifChoice {
    case giphy(GiphyGIF)
    case video(KeychainAnimation)
}

/// GIPHY search (https://developers.giphy.com/docs/api/). The API key is the owner's own: Settings /
/// the GIFs tab (`keyDefaultsKey`), else `GiphyAPIKey` in Info.plist. Never committed. A beta key allows
/// 100 calls an hour. "Powered by GIPHY" must show wherever results are shown (the GIFs tab does).
enum GiphyClient {
    static let keyDefaultsKey = "giphyAPIKey"
    static let plistKey = "GiphyAPIKey"
    static let pageSize = 24

    static var apiKey: String? {
        let saved = UserDefaults.standard.string(forKey: keyDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !saved.isEmpty { return saved }
        let plist = (Bundle.main.object(forInfoDictionaryKey: plistKey) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return plist.isEmpty ? nil : plist
    }

    enum Failure: LocalizedError {
        case noKey, badKey, rateLimited, gone, http(Int)
        var errorDescription: String? {
            switch self {
            case .noKey: return "Add your GIPHY API key to search GIFs."
            case .badKey: return "GIPHY didn\u{2019}t accept that API key. Check it and paste it again."
            case .rateLimited: return "GIPHY\u{2019}s limit for this key is reached (100 searches an hour). Try again later."
            case .gone: return "That GIF isn\u{2019}t on GIPHY any more."
            case .http(let code): return "GIPHY didn\u{2019}t answer properly (error \(code)). Try again in a moment."
            }
        }
    }

    /// `query` empty = trending.
    static func search(_ query: String, offset: Int = 0) async throws -> [GiphyGIF] {
        guard let key = apiKey else { throw Failure.noKey }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var c = URLComponents(string: trimmed.isEmpty
                              ? "https://api.giphy.com/v1/gifs/trending"
                              : "https://api.giphy.com/v1/gifs/search")!
        var items = [
            URLQueryItem(name: "api_key", value: key),
            URLQueryItem(name: "limit", value: String(pageSize)),
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "rating", value: "pg-13"),
        ]
        if !trimmed.isEmpty { items.append(URLQueryItem(name: "q", value: trimmed)) }
        c.queryItems = items
        let (data, response) = try await URLSession.shared.data(from: c.url!)
        try check(response)
        return try JSONDecoder().decode(Response.self, from: data).data.compactMap(\.gif)
    }

    /// The GIF to send (downloaded each time it is shown, never kept).
    static func download(_ gif: GiphyGIF) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: gif.sendURL)
        try check(response)
        return data
    }

    private static func check(_ response: URLResponse) throws {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch code {
        case 200: return
        case 401, 403: throw Failure.badKey
        case 404, 410: throw Failure.gone
        case 429: throw Failure.rateLimited
        default: throw Failure.http(code)
        }
    }

    private struct Response: Decodable {
        let data: [Item]
    }

    private struct Rendition: Decodable {
        let url: String?
    }

    private struct Item: Decodable {
        let id: String
        let title: String?
        let images: [String: Rendition]

        var gif: GiphyGIF? {
            func url(_ name: String) -> URL? { images[name]?.url.flatMap(URL.init(string:)) }
            guard let send = url("fixed_width") ?? url("downsized") else { return nil }
            let preview = url("fixed_width_small") ?? url("fixed_width_downsampled") ?? send
            return GiphyGIF(id: id, title: title ?? "", sendURL: send, previewURL: preview)
        }
    }
}

// MARK: - Search state

/// The GIFs tab's search, kept for the whole app run so switching tabs or reopening the Photos page
/// doesn't spend another of the key's 100 calls an hour. Only the newest load may change the results.
@MainActor
final class GifSearchModel: ObservableObject {
    static let shared = GifSearchModel()

    @Published var query = ""
    @Published private(set) var results: [GiphyGIF] = []
    /// The query `results` belong to; nil until the first load.
    @Published private(set) var shownQuery: String?
    @Published private(set) var searching = false
    @Published private(set) var canLoadMore = false
    @Published private(set) var error: String?

    private var loadGen = 0
    /// Trending, kept so clearing the search shows it again without a call. Refreshed after 15 min.
    private var trending: (gifs: [GiphyGIF], more: Bool, at: Date)?
    private let trendingTTL: TimeInterval = 15 * 60

    private init() {}

    /// First open (or trending gone stale): load trending.
    func loadIfNeeded() async {
        if shownQuery == nil {
            await load(reset: true)
        } else if shownQuery == "", let t = trending, Date().timeIntervalSince(t.at) > trendingTTL {
            await load(reset: true)
        }
    }

    /// The ✕ in the search field: back to trending (cached when fresh).
    func clearSearch() {
        query = ""
        if let t = trending, Date().timeIntervalSince(t.at) <= trendingTTL {
            loadGen += 1  // a search still loading must not land over trending
            searching = false
            results = t.gifs
            canLoadMore = t.more
            shownQuery = ""
            error = nil
        } else {
            Task { await load(reset: true) }
        }
    }

    func load(reset: Bool) async {
        guard GiphyClient.apiKey != nil else {
            error = GiphyClient.Failure.noKey.errorDescription
            return
        }
        loadGen += 1
        let gen = loadGen
        let q = reset ? query.trimmingCharacters(in: .whitespacesAndNewlines) : (shownQuery ?? "")
        let offset = reset ? 0 : results.count
        searching = true
        error = nil
        do {
            let page = try await GiphyClient.search(q, offset: offset)
            guard gen == loadGen else { return }
            if reset {
                results = page
            } else {
                let have = Set(results.map(\.id))
                results += page.filter { !have.contains($0.id) }
            }
            shownQuery = q
            canLoadMore = page.count == GiphyClient.pageSize
            if q.isEmpty { trending = (results, canLoadMore, Date()) }
        } catch {
            guard gen == loadGen else { return }
            self.error = error.localizedDescription
        }
        searching = false
    }
}

// MARK: - Video picking

/// A video picked from the photo library, copied to a temporary file the app owns (deleted after use).
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}

// MARK: - Animated thumbnails

/// Plays a GIPHY preview in a square, stretched like the keychain shows it. Reduce Motion: first frame.
struct GifThumb: View {
    let url: URL
    @State private var image: UIImage?
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    // A UIKit view inside a Button's label takes the touch and the Button never fires
                    // (owner, 2026-11-24: "it doesn't do anything when I click them").
                    AnimatedImageView(image: image)
                        .allowsHitTesting(false)
                } else {
                    theme.artSurface
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .task(id: url) {
                let key = (url.absoluteString + (reduceMotion ? "|still" : "")) as NSString
                if let cached = Self.cache.object(forKey: key) {
                    image = cached
                    return
                }
                guard let loaded = try? await URLSession.shared.data(from: url) else { return }
                let data = loaded.0
                let still = reduceMotion
                let decoded = await Task.detached(priority: .userInitiated) {
                    GifThumb.decode(data, still: still)
                }.value
                if let decoded {
                    Self.cache.setObject(decoded, forKey: key, cost: Self.cost(of: decoded))
                }
                image = decoded
            }
    }

    static let side = 128
    static let maxFrames = 20

    /// ~1.3 MB at most per thumb (20 frames x 128 x 128 x 4); the cache keeps ~40 MB.
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 40 << 20
        return c
    }()

    private static func cost(of image: UIImage) -> Int {
        let w = Int(image.size.width * image.scale)
        let h = Int(image.size.height * image.scale)
        return w * h * 4 * max(1, image.images?.count ?? 1)
    }

    /// Small animated image, stretched to a 128 px square, at most 20 frames.
    nonisolated static func decode(_ data: Data, still: Bool) -> UIImage? {
        guard let frames = AnimationPrep.gifFrames(data, maxFrames: still ? 1 : maxFrames) else { return nil }
        var images: [UIImage] = []
        var total = 0
        for f in frames {
            guard let square = AnimationPrep.squareImage(f.image, side: side) else { continue }
            images.append(UIImage(cgImage: square))
            total += f.ms
        }
        guard let first = images.first else { return nil }
        if still || images.count == 1 { return first }
        return UIImage.animatedImage(with: images, duration: Double(total) / 1000)
    }
}

/// `UIImageView` plays animated `UIImage`s by itself; SwiftUI's `Image` shows only the first frame.
/// `pixelated`: scale up without smoothing, so the keychain's 120 px frames look like its screen.
struct AnimatedImageView: UIViewRepresentable {
    let image: UIImage
    var pixelated = false

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.isUserInteractionEnabled = false  // taps belong to the SwiftUI around it
        view.contentMode = .scaleToFill
        view.clipsToBounds = true
        for axis in [NSLayoutConstraint.Axis.horizontal, .vertical] {
            view.setContentHuggingPriority(.defaultLow, for: axis)
            view.setContentCompressionResistancePriority(.defaultLow, for: axis)
        }
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {
        view.layer.magnificationFilter = pixelated ? .nearest : .linear
        if view.image !== image { view.image = image }
    }
}
