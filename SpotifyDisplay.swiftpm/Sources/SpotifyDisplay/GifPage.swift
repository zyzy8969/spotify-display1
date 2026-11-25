import SwiftUI
import PhotosUI
import UIKit

/// The GIFs tab of the Photos page: GIFs you showed lately (star the ones you like: a starred GIF can be
/// the start-up picture), a GIPHY search, and "Make a GIF from a video" with iOS's own trimmer (up to
/// 15 s). Whatever you tap is shown on the keychain (BLE_PROTOCOL 1.25) and on the app's cover.
@MainActor
struct GifPageContent: View {
    let onSend: (GifChoice) -> Void
    let close: () -> Void

    @ObservedObject private var search = GifSearchModel.shared
    @ObservedObject private var library = GifLibrary.shared
    /// Only read, so the tab updates when a development key is set in Settings > Advanced.
    @AppStorage(GiphyClient.keyDefaultsKey) private var giphyKey = ""
    @Environment(\.theme) private var theme

    // Video -> GIF.
    @State private var pickedVideo: PhotosPickerItem?
    /// The picked video (a temporary copy) waiting in the trimmer.
    @State private var trimming: TrimRequest?
    /// Its file, until the trimmer hands back a result (a swiped-away trimmer leaves it to delete).
    @State private var untrimmedURL: URL?
    @State private var loadingVideo = false
    /// 0...1 while frames are read; nil when not converting.
    @State private var videoProgress: Double?
    @State private var videoError: String?
    @State private var videoTask: Task<Void, Never>?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !library.items.isEmpty { recentRow }

            if GiphyClient.apiKey == nil {
                keyEntry
            } else {
                searchField
            }
            videoSection

            heading(search.shownQuery?.isEmpty == false ? "Results" : "Trending",
                    note: "Tap one to show it. Touch and hold to add it to your favourites. It plays on the keychain until you tap the cover or the keychain turns off.")
            if let error = search.error, GiphyClient.apiKey != nil {
                Text(error)
                    .themeText(.footnote)
                    .foregroundStyle(theme.inkSoft)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(search.results) { gif in
                    Button {
                        send(.giphy(gif))
                    } label: {
                        GifThumb(url: gif.previewURL)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            library.addGiphy(gif, favorite: true)
                        } label: {
                            Label("Add to favourites", systemImage: "star")
                        }
                    }
                    .accessibilityLabel(gif.title.isEmpty ? "GIF" : gif.title)
                    .accessibilityHint("Shows it on the display. Touch and hold to add it to your favourites.")
                }
            }
            if search.searching {
                ProgressView().frame(maxWidth: .infinity, minHeight: 44)
            } else if search.canLoadMore {
                Button {
                    Task { await search.load(reset: false) }
                } label: {
                    Text("More")
                        .themeText(.row)
                        .foregroundStyle(theme.ink)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            // GIPHY's terms: "Powered By GIPHY" wherever its results are shown.
            Text("Powered by GIPHY")
                .themeText(.statCaption)
                .foregroundStyle(theme.inkFaint)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .task { await search.loadIfNeeded() }
        .onChange(of: pickedVideo) { item in
            guard let item else { return }
            pickedVideo = nil
            openVideo(item)
        }
        .sheet(item: $trimming, onDismiss: {
            // Dismissed without a choice (swiped away): the copy is not needed any more.
            if let url = untrimmedURL { try? FileManager.default.removeItem(at: url) }
            untrimmedURL = nil
        }) { request in
            VideoTrimmer(path: request.url.path, maxSeconds: AnimationPrep.videoMaxSeconds) { result in
                untrimmedURL = nil
                trimming = nil
                switch result {
                case .trimmed(let path):
                    if path != request.url.path { try? FileManager.default.removeItem(at: request.url) }
                    makeGIF(URL(fileURLWithPath: path))
                case .cancelled:
                    try? FileManager.default.removeItem(at: request.url)
                case .failed:
                    // The trimmer could not open it: use the start of the video as it is.
                    makeGIF(request.url)
                }
            }
            .ignoresSafeArea()
        }
        .onDisappear {
            // Closing the page abandons a conversion: nothing is sent later on its own.
            videoTask?.cancel()
        }
    }

    // MARK: Recent and favourites

    /// GIFs shown lately, starred ones marked. One row that scrolls sideways, so search results stay high.
    private var recentRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading("Recent", note: "Touch and hold to star one. Starred GIFs can be the start-up picture (Settings).")
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(library.items) { item in
                        Button {
                            send(.saved(item))
                        } label: {
                            SavedGifThumb(item: item)
                                .frame(width: 84, height: 84)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                library.toggleFavorite(item)
                            } label: {
                                Label(item.isFavorite ? "Remove from favourites" : "Add to favourites",
                                      systemImage: item.isFavorite ? "star.slash" : "star")
                            }
                            Button(role: .destructive) {
                                library.remove(item)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                        .accessibilityLabel((item.giphy.map { $0.title.isEmpty ? "GIF" : $0.title } ?? "Your GIF")
                                            + (item.isFavorite ? ", favourite" : ""))
                        .accessibilityHint("Shows it on the display. Touch and hold to star or remove it.")
                    }
                }
            }
        }
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.inkSoft)
                .padding(.leading, 12)
                .accessibilityHidden(true)
            TextField("", text: $search.query, prompt: Text("Search GIPHY").foregroundColor(theme.inkFaint))
                .themeText(.row)
                .foregroundStyle(theme.ink)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .onSubmit { Task { await search.load(reset: true) } }
                .accessibilityLabel("Search GIPHY")
            if !search.query.isEmpty || search.shownQuery?.isEmpty == false {
                Button {
                    search.clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(theme.inkFaint)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .accessibilityHint("Shows trending GIFs again")
            }
        }
        .frame(minHeight: 48)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(theme.ringOff, lineWidth: 1))
    }

    /// No key in this build. Customers never handle keys: the cloud build puts the app's own key in
    /// (GitHub secret `GIPHY_API_KEY`); the Settings override is only for development.
    private var keyEntry: some View {
        heading("GIF search", note: "GIF search isn\u{2019}t set up in this version of the app. You can still make a GIF from one of your videos.")
    }

    // MARK: Video

    private var videoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            PhotosPicker(selection: $pickedVideo, matching: .videos, preferredItemEncoding: .current) {
                HStack(spacing: 8) {
                    if loadingVideo {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "film")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    Text("Make a GIF from a video")
                        .themeText(.row)
                    Text("up to \(Int(AnimationPrep.videoMaxSeconds)) s")
                        .themeText(.statCaption)
                        .foregroundStyle(theme.inkFaint)
                }
                .foregroundStyle(theme.ink)
                .frame(maxWidth: .infinity, minHeight: 48)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(theme.ringOff, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .disabled(loadingVideo || videoProgress != nil)
            .accessibilityHint("Pick a video, trim it to the part you want, and show it on the display")
            if let videoProgress {
                ProgressView(value: videoProgress) {
                    Text("Making the GIF\u{2026}")
                        .themeText(.footnote)
                        .foregroundStyle(theme.inkSoft)
                }
            }
            if let videoError {
                Text(videoError)
                    .themeText(.footnote)
                    .foregroundStyle(theme.inkSoft)
            }
        }
    }

    private func heading(_ title: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .themeText(.eyebrow)
                .foregroundStyle(theme.inkFaint)
                .accessibilityAddTraits(.isHeader)
            Text(note)
                .themeText(.footnote)
                .foregroundStyle(theme.inkSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func send(_ choice: GifChoice) {
        onSend(choice)
        close()
    }

    /// Copies the picked video, then opens iOS's trimmer on it.
    private func openVideo(_ item: PhotosPickerItem) {
        videoTask?.cancel()
        videoError = nil
        loadingVideo = true
        videoTask = Task {
            // A cancelled pick must not stop the spinner of the pick that replaced it.
            defer { if !Task.isCancelled { loadingVideo = false } }
            guard let movie = try? await item.loadTransferable(type: PickedMovie.self) else {
                if !Task.isCancelled { videoError = "Could not read that video." }
                return
            }
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: movie.url)
                return
            }
            if UIVideoEditorController.canEditVideo(atPath: movie.url.path) {
                untrimmedURL = movie.url
                trimming = TrimRequest(url: movie.url)
            } else {
                makeGIF(movie.url)  // can't trim this one: its first 15 s
            }
        }
    }

    /// Converts the (trimmed) clip and shows it. The temporary file is deleted afterwards.
    private func makeGIF(_ url: URL) {
        videoError = nil
        videoProgress = 0
        videoTask = Task {
            defer { try? FileManager.default.removeItem(at: url) }
            let made = await AnimationPrep.fromVideo(url: url) { p in
                Task { @MainActor in
                    if videoProgress != nil { videoProgress = p }
                }
            }
            guard !Task.isCancelled else { return }
            videoProgress = nil
            guard let made else {
                videoError = "Could not make a GIF from that video."
                return
            }
            send(.video(made))
        }
    }
}

/// A video waiting in the trimmer.
struct TrimRequest: Identifiable {
    let id = UUID()
    let url: URL
}

/// iOS's own video trimmer (the yellow handles), capped at `maxSeconds`. Reports the trimmed file's path.
struct VideoTrimmer: UIViewControllerRepresentable {
    enum Result { case trimmed(String), cancelled, failed }

    let path: String
    let maxSeconds: Double
    let done: (Result) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    func makeUIViewController(context: Context) -> UIVideoEditorController {
        let editor = UIVideoEditorController()
        editor.videoPath = path
        editor.videoMaximumDuration = maxSeconds
        editor.videoQuality = .typeMedium  // frames end up 120 px; no need for full quality
        editor.delegate = context.coordinator
        return editor
    }

    func updateUIViewController(_ editor: UIVideoEditorController, context: Context) {}

    final class Coordinator: NSObject, UIVideoEditorControllerDelegate, UINavigationControllerDelegate {
        let done: (Result) -> Void
        /// The editor can report a save twice; only the first counts.
        private var finished = false

        init(done: @escaping (Result) -> Void) { self.done = done }

        private func finish(_ result: Result) {
            guard !finished else { return }
            finished = true
            done(result)
        }

        func videoEditorController(_ editor: UIVideoEditorController, didSaveEditedVideoToPath editedVideoPath: String) {
            finish(.trimmed(editedVideoPath))
        }

        func videoEditorControllerDidCancel(_ editor: UIVideoEditorController) {
            finish(.cancelled)
        }

        func videoEditorController(_ editor: UIVideoEditorController, didFailWithError error: Error) {
            finish(.failed)
        }
    }
}
