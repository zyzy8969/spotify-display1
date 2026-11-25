import SwiftUI
import PhotosUI

/// The GIFs tab of the Photos page: pick a GIF from GIPHY, or turn 4 seconds of one of your videos into
/// one. Either is shown on the keychain (BLE_PROTOCOL 1.25) and on the app's cover. Nothing is saved
/// (owner, 2026-11-24: favourites live on the Photos tab).
@MainActor
struct GifPageContent: View {
    let onSend: (GifChoice) -> Void
    let close: () -> Void

    @ObservedObject private var search = GifSearchModel.shared
    @AppStorage(GiphyClient.keyDefaultsKey) private var giphyKey = ""
    @Environment(\.theme) private var theme
    /// A key being pasted, saved only on "Use this key" (the field would vanish after one character).
    @State private var draftKey = ""

    // Video -> GIF.
    @State private var pickedVideo: PhotosPickerItem?
    /// The picked video (a temporary copy), waiting for "Make GIF".
    @State private var movieURL: URL?
    @State private var movieDuration: Double = 0
    @State private var clipStart: Double = 0
    @State private var startStill: UIImage?
    @State private var loadingVideo = false
    /// 0...1 while frames are read; nil when not converting.
    @State private var videoProgress: Double?
    @State private var videoError: String?
    @State private var videoTask: Task<Void, Never>?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if GiphyClient.apiKey == nil {
                keyEntry
            } else {
                searchField
            }
            videoSection

            heading(search.shownQuery?.isEmpty == false ? "Results" : "Trending",
                    note: "Tap one to show it. It plays on the keychain until you tap the cover or the keychain turns off. Sending takes about 5\u{2013}10 seconds.")
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
                    .accessibilityLabel(gif.title.isEmpty ? "GIF" : gif.title)
                    .accessibilityHint("Shows it on the display")
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
        .onDisappear {
            // Closing the page abandons a video: nothing is sent later on its own.
            videoTask?.cancel()
            discardVideo()
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

    /// No key yet: paste it right here (the same setting as Settings > Advanced).
    private var keyEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            heading("GIPHY key", note: "To search GIPHY, paste your free API key from developers.giphy.com (Create an App, then API). It stays on this phone.")
            TextField("", text: $draftKey, prompt: Text("Paste your GIPHY key").foregroundColor(theme.inkFaint))
                .themeText(.rowValue)
                .foregroundStyle(theme.ink)
                .keyboardType(.asciiCapable)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.done)
                .onSubmit(useKey)
                .padding(.horizontal, 12)
                .frame(minHeight: 48)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(theme.ringOff, lineWidth: 1))
                .accessibilityLabel("GIPHY API key")
            textButton("Use this key", action: useKey)
                .disabled(draftKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    // MARK: Video

    @ViewBuilder
    private var videoSection: some View {
        if let movieURL {
            videoPanel(movieURL)
        } else {
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
                }
                .foregroundStyle(theme.ink)
                .frame(maxWidth: .infinity, minHeight: 48)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(theme.ringOff, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .disabled(loadingVideo)
            .accessibilityHint("Pick a video, choose where its 4 seconds start, and show it on the display")
            if let videoError {
                Text(videoError)
                    .themeText(.footnote)
                    .foregroundStyle(theme.inkSoft)
            }
        }
    }

    /// Choose where the clip starts, then make it. Progress is the share of frames read.
    private func videoPanel(_ url: URL) -> some View {
        let clip = AnimationPrep.videoClipSeconds
        let latest = max(0, movieDuration - clip)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Group {
                    if let startStill {
                        Image(uiImage: startStill).resizable()
                    } else {
                        theme.artSurface
                    }
                }
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your video")
                        .themeText(.row)
                        .foregroundStyle(theme.ink)
                    Text(String(format: "%.1f\u{2013}%.1f s of %.1f s", clipStart, min(movieDuration, clipStart + clip), movieDuration))
                        .themeText(.footnote)
                        .foregroundStyle(theme.inkSoft)
                }
            }
            if latest > 0.05 {
                Slider(value: $clipStart, in: 0...latest, onEditingChanged: { editing in
                    if !editing { refreshStill(url) }
                })
                .disabled(videoProgress != nil)
                .accessibilityLabel("GIF start")
                .accessibilityValue(String(format: "%.1f seconds", clipStart))
            }
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
            HStack(spacing: 24) {
                textButton(videoProgress == nil ? "Make GIF" : "Making\u{2026}") { makeGIF(url) }
                    .disabled(videoProgress != nil)
                textButton("Cancel") {
                    videoTask?.cancel()
                    discardVideo()
                }
            }
        }
        .padding(12)
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(theme.ringOff, lineWidth: 1))
    }

    private func textButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .themeText(.row)
                .foregroundStyle(theme.ink)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

    /// Saves the pasted key (the same setting as Settings > Advanced) and loads trending with it.
    private func useKey() {
        let key = draftKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        giphyKey = key
        draftKey = ""
        Task { await search.load(reset: true) }
    }

    private func send(_ choice: GifChoice) {
        onSend(choice)
        close()
    }

    private func openVideo(_ item: PhotosPickerItem) {
        videoTask?.cancel()
        discardVideo()
        loadingVideo = true
        videoTask = Task {
            // A cancelled pick must not stop the spinner of the pick that replaced it.
            defer { if !Task.isCancelled { loadingVideo = false } }
            guard let movie = try? await item.loadTransferable(type: PickedMovie.self) else {
                if !Task.isCancelled { videoError = "Could not read that video." }
                return
            }
            // Checked after the await: the page may have closed meanwhile (then the copy is deleted here).
            guard let duration = await AnimationPrep.videoDuration(url: movie.url), !Task.isCancelled else {
                try? FileManager.default.removeItem(at: movie.url)
                if !Task.isCancelled { videoError = "Could not read that video." }
                return
            }
            movieURL = movie.url
            movieDuration = duration
            clipStart = 0
            refreshStill(movie.url)
        }
    }

    private func refreshStill(_ url: URL) {
        let at = clipStart
        Task {
            let still = await AnimationPrep.videoStill(url: url, at: at)
            if movieURL == url, clipStart == at { startStill = still }
        }
    }

    private func makeGIF(_ url: URL) {
        videoError = nil
        videoProgress = 0
        let start = clipStart
        videoTask = Task {
            let made = await AnimationPrep.fromVideo(url: url, start: start) { p in
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
            discardVideo()
            send(.video(made))
        }
    }

    /// Deletes the temporary copy of the picked video and resets the panel.
    private func discardVideo() {
        if let movieURL { try? FileManager.default.removeItem(at: movieURL) }
        movieURL = nil
        movieDuration = 0
        clipStart = 0
        startStill = nil
        videoProgress = nil
    }
}
