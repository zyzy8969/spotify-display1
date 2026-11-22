import SwiftUI
import CoreBluetooth
import UIKit

/// ESP32 GATT contract — repo `spotify-display1`: `docs/BLE_PROTOCOL.md`, `src/main.cpp`, `python/spotify_album_sender.py`.
@MainActor
final class BLEManager: NSObject, ObservableObject {
    @Published private(set) var isConnected = false
    @Published var currentAlbumArt: Data?
    @Published var statusMessage = "Bluetooth…" {
        didSet { if statusMessage != oldValue { log("status  \(statusMessage)", kind: .info) } }
    }
    @Published var isTransferring = false
    @Published var transferProgress: Double = 0
    /// Total `.bin` files in `/cache` on the display (from stats / `CACHE_COUNT:`). `nil` until first successful read this connection.
    @Published private(set) var sdCacheEntryCount: Int?
    /// True after connect until the first post-`READY` cache stats request finishes (success or failure).
    @Published private(set) var sdCacheCountLoading = false
    /// Increments whenever GATT is fully ready after (re)connect; consumers can use this as a sync session token.
    @Published private(set) var readyEpoch: UInt64 = 0
    /// Backlight level used when the user has never moved the slider.
    static let defaultBrightness: UInt8 = 200
    /// Persisted backlight level. `integer(forKey:)` cannot tell "never set" from a stored 0,
    /// so read the object first — otherwise a fresh install pushes 0 on connect and the display
    /// goes dark (harmless only while the firmware's LEDC channel bug swallowed the write).
    @Published var brightness: UInt8 = {
        guard let stored = UserDefaults.standard.object(forKey: "ble_brightness") as? Int else {
            return BLEManager.defaultBrightness
        }
        return UInt8(clamping: stored)
    }()
    /// Board status LED brightness (BLE_PROTOCOL 1.13, ffe6): 0...255 of the board's own safe cap
    /// (~47 % of the LED's full power). 255 = the cap, 0 = off. Re-sent on every connect.
    @Published private(set) var statusLedLevel: UInt8 = {
        guard let stored = UserDefaults.standard.object(forKey: "ble_status_led") as? Int else { return 255 }
        return UInt8(clamping: stored)
    }()
    /// The connected board has the status-LED characteristic (firmware with BLE_PROTOCOL 1.13+).
    @Published private(set) var boardSupportsStatusLed = false
    @Published private(set) var transferLog: [TransferLogEntry] = []
    @Published private(set) var currentLivePhase: String? = "idle"
    /// Typed pipeline stage for the UI, so views never parse `currentLivePhase` / `boardAckStatus`
    /// text. UI-only: nothing in the transfer path reads it. Reset to `.idle` on every exit from
    /// `processTrack`, including errors and cancellation.
    @Published private(set) var sendStage: SendStage = .idle
    /// Bumped per `processTrack` call, so an older call unwinding after a skip cannot reset the
    /// newer call's `sendStage` or overwrite its preview art.
    private var sendStageGen: UInt64 = 0
    /// Shows "Cache hit" / "Sent to display" / nil on main screen.
    @Published private(set) var lastTransferResult: String?
    /// Human-readable board confirmation for latest transfer stage.
    @Published private(set) var boardAckStatus: String?
    /// Track id most recently confirmed on-board (cache hit draw or BLE SUCCESS).
    @Published private(set) var lastConfirmedTrackId: String?
    private let maxLogEntries = 30

    /// Called on MainActor when GATT is fully ready after (re)connect. SpotifyManager registers this for instant resync.
    var onReadyCallback: (() -> Void)?

    /// Called on MainActor for each board heartbeat (`HB` message, every ~1 s while connected).
    /// iOS wakes the suspended app for each notify, so this is the background poll trigger.
    var onHeartbeat: (() -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var statusChar: CBCharacteristic?
    private var cacheChar: CBCharacteristic?
    private var imageChar: CBCharacteristic?
    private var msgChar: CBCharacteristic?
    private var brightnessChar: CBCharacteristic?
    /// Optional (older firmware lacks it); never part of the "GATT ready" check.
    private var statusLedChar: CBCharacteristic?

    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var cacheContinuation: CheckedContinuation<Bool, Error>?
    private var transferContinuation: CheckedContinuation<Void, Error>?
    private var statsContinuation: CheckedContinuation<Int, Error>?
    private var clearContinuation: CheckedContinuation<Void, Error>?
    private var cacheRenderContinuation: CheckedContinuation<Void, Error>?
    /// CoreBluetooth write queue (without-response) drain signal
    private var writeDrainContinuation: CheckedContinuation<Void, Never>?

    /// Generation counters so stale timeout tasks don't cancel a newer continuation.
    private var cacheCheckGen: UInt64 = 0
    private var statsCheckGen: UInt64 = 0
    private var readyCheckGen: UInt64 = 0
    private var cacheRenderGen: UInt64 = 0
    private var clearCheckGen: UInt64 = 0
    private var transferTimeoutGen: UInt64 = 0
    private var writeDrainGen: UInt64 = 0
    private var boardIdleGen: UInt64 = 0

    /// Replies the board still owes for requests this app sent, even after the app stopped waiting
    /// (a skip cancels the app's wait, not the board's work). The firmware keeps one cache-check flag
    /// and one key, and its replies carry no song id, so a check sent while one is owed gets the old
    /// song's answer matched to the new song. `processTrack` waits these out before asking again.
    private var cacheReplyOwed = false
    private var imageAckOwed = false
    private var boardIdleWaiters: [CheckedContinuation<Void, Never>] = []
    /// Cap on waiting for an owed reply: a cache hit replies only after its transition finishes.
    private let boardIdleTimeoutNs: UInt64 = 8_000_000_000

    private var sawReady = false
    /// Ensures `readyEpoch` increments at most once per BLE connection even if characteristics discovery runs more than once.
    private var readyEpochCommittedForConnection = false
    private var awaitingImageComplete = false
    private var awaitingCacheRenderConfirm = false
    private var cacheRenderConfirmed = false
    /// Last transition announced by firmware via `MESSAGE` notify (`TRANSITION:<name>`).
    @Published private(set) var lastTransitionName: String?
    /// Every `TRANSITION:` announcement (cache hits since 1.7, fresh draws too since 1.12). The main
    /// cover replays it so the app shows the effect the board just drew.
    @Published private(set) var transitionEvent: TransitionEvent?
    /// The LE RGB565 frame the board shows now, i.e. what its next transition starts from. Set when
    /// the board starts drawing a frame (`TRANSITION_START`) and again when a draw is confirmed:
    /// a fresh send's bytes, a cache hit's downloaded cover converted exactly like a send (so it
    /// matches the SD copy), a photo's bytes. nil = waiting screen (after a disconnect) or unknown.
    @Published private(set) var boardFrame: Data?
    /// Newest `TRANSITION_START` (BLE_PROTOCOL 1.13): the board is about to draw a transition.
    /// `newFrame` is filled in when the app has it (for a cache hit, once the cover is converted).
    @Published private(set) var transitionStart: TransitionStartEvent?
    /// What the board was last asked to draw, so a `TRANSITION_START` knows its new frame. The board
    /// works on one request at a time (the app waits out owed replies), so the newest one is it.
    private enum DrawRequest {
        case image(Data)
        case cacheCheck(Task<Data?, Never>)
    }
    private var lastDrawRequest: DrawRequest?
    /// Bumped per draw request; a late cache-hit conversion only sets `boardFrame` if none came after.
    private var drawRequestGen: UInt64 = 0
    /// Cache-key sources of covers stored ahead of time this session (prefetch). A later cache hit on
    /// one of them is a song the person has not seen yet: the pop-up says "new", not "cache".
    private var prefetchedKeySources: Set<String> = []
    /// Albums the keychain has shown (`PlayedAlbums`), oldest first, plus a set for lookups.
    private var playedAlbumOrder: [String] = PlayedAlbums.load()
    private lazy var playedAlbumSet: Set<String> = Set(playedAlbumOrder)

    /// What "played before" is keyed on: the album (same album = same cover = not new), or the track
    /// for a song without an album id.
    private func playKey(albumId: String?, trackId: String) -> String {
        if let albumId, !albumId.isEmpty { return "a:" + albumId }
        return "t:" + trackId
    }

    /// The keychain is showing this album; true if it is the first time.
    @discardableResult
    private func markAlbumPlayed(_ key: String) -> Bool {
        guard !playedAlbumSet.contains(key) else { return false }
        playedAlbumSet.insert(key)
        playedAlbumOrder.append(key)
        if playedAlbumOrder.count > PlayedAlbums.cap + 200 {
            playedAlbumOrder.removeFirst(playedAlbumOrder.count - PlayedAlbums.cap)
            playedAlbumSet = Set(playedAlbumOrder)
        }
        PlayedAlbums.save(playedAlbumOrder)
        return true
    }
    private var mirror: TransitionMirror { TransitionMirror.shared }
    /// Rolling terminal-style log for the Live tab (newest last).
    @Published private(set) var eventLog: [LogLine] = []
    private let maxLogLines = 300
    /// Board said `CAPS:transitions` (BLE_PROTOCOL 1.12): it takes the enabled-transitions mask, the
    /// display-only header byte, and announces fresh draws.
    @Published private(set) var boardSupportsTransitionMask = false
    /// Board said `CAPS:speeds` (BLE_PROTOCOL 1.14): it takes the transition-speeds write and appends
    /// the speed it used to `TRANSITION_START`.
    @Published private(set) var boardSupportsSpeeds = false
    /// Board said `CAPS:t128` (BLE_PROTOCOL 1.15): transitions 52-116 exist, it reads the 128-bit mask
    /// and takes speeds for all 117 indices.
    @Published private(set) var boardSupports128 = false
    /// Board said `CAPS:next` (BLE_PROTOCOL 1.16): it takes the one-shot next-draw transition write.
    @Published private(set) var boardSupportsNextTransition = false
    /// Board said `CAPS:newsong` (BLE_PROTOCOL 1.17): it takes the new-song cache check.
    @Published private(set) var boardSupportsNewSong = false
    /// The view set this for a photo <-> cover swap: the next draw this app asks for (the photo, or the
    /// cover coming back) plays Card Flip on the keychain, like the app's card. Cleared once sent.
    var flipNextDraw = false
    /// Card Flip (header index 23).
    static let swapFlipTransition: UInt8 = 23
    /// A photo the person uploaded is on the display: Spotify sends are paused until `endPhotoHold()`.
    @Published private(set) var photoHold = false
    /// The last photo the person uploaded (square JPEG), so tapping the cover can show it again.
    /// In memory only: gone when the app quits.
    @Published private(set) var lastPhotoJPEG: Data?

    /// Set in `centralManager(_:willRestoreState:)` and consumed when the central becomes `.poweredOn`.
    private var pendingRestoredPeripheral: CBPeripheral?

    /// Lets an in-flight album transfer finish after the app moves to background (best-effort, seconds).
    private var transferBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    /// Cancels the 32s `SUCCESS` wait when the firmware ACKs early (saves idle sleep + CPU).
    private var imageSuccessTimeoutTask: Task<Void, Never>?

    /// Incremented on `cancelOngoingTransfer()` and `failPending` so in-flight `processTrack` / `sendRGB565` abort cooperatively.
    private var transferEpoch: UInt64 = 0
    private var activeDownloadTask: Task<Data, Error>?

    /// Cache keys successfully sent via BLE this session. Only trust firmware cache hits for keys in this set.
    private var confirmedCacheKeys = Set<Data>()

    private let serviceUUID = CBUUID(string: "0000FFE0-0000-1000-8000-00805F9B34FB")
    private let statusUUID = CBUUID(string: "0000FFE1-0000-1000-8000-00805F9B34FB")
    private let cacheUUID = CBUUID(string: "0000FFE2-0000-1000-8000-00805F9B34FB")
    private let imageUUID = CBUUID(string: "0000FFE3-0000-1000-8000-00805F9B34FB")
    private let messageUUID = CBUUID(string: "0000FFE4-0000-1000-8000-00805F9B34FB")
    private let brightnessUUID = CBUUID(string: "0000FFE5-0000-1000-8000-00805F9B34FB")
    private let statusLedUUID = CBUUID(string: "0000FFE6-0000-1000-8000-00805F9B34FB")

    /// Same as firmware `IMAGE_SIZE` (240×240×2).
    private let imagePayloadBytes = 115_200
    private let chunkSize = 512
    private let cacheMagic = UInt32(0xDEADBEEF)
    /// BLE_PROTOCOL 1.8 prefetch: "is this cover on SD?" without drawing it.
    private let cacheProbeMagic = UInt32(0xDEADBEE0)
    /// BLE_PROTOCOL 1.17: a normal cache check for a song the keychain has never shown (orange LED).
    private let cacheNewSongMagic = UInt32(0xDEADBEE1)
    /// BLE_PROTOCOL 1.8 prefetch: image header transition byte meaning "save to SD, don't draw".
    private let storeOnlyTransition: UInt8 = 0xFE
    /// BLE_PROTOCOL 1.12: header byte meaning "draw it, don't save it to SD" (photo upload).
    private let displayOnlyTransition: UInt8 = 0xFD
    /// BLE_PROTOCOL 1.12: Cache characteristic write carrying the enabled-transitions bitmask.
    private let transitionMaskMagic = UInt32(0xCAC4E1EB)
    /// BLE_PROTOCOL 1.16: one-shot transition for the next drawn frame.
    private let nextTransitionMagic = UInt32(0xCAC4E1ED)
    /// BLE_PROTOCOL 1.11: image header format byte for a raw-DEFLATE payload (10-byte header).
    private let deflateFormat: UInt8 = 0x01
    /// Board said `CAPS:deflate` (in reply to the stats request sent on every connect). Cleared on
    /// disconnect, and for the rest of the connection if the board ever fails to inflate a frame.
    private var boardSupportsDeflate = false
    /// Below this saving a frame goes raw: inflating costs the board ~20 ms, not worth it for <10%.
    private let minDeflateSaving = 0.9
    /// Must match `main.cpp` stats request magic.
    private let statsMagic = UInt32(0xC0FFEEE1)

    private static var centralRestoreIdentifier: String {
        (Bundle.main.bundleIdentifier ?? "SpotifyDisplay") + ".bleCentral"
    }

    override init() {
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.centralRestoreIdentifier]
        )
    }

    /// Background time is counted, not on/off. On a skip the cancelled `processTrack` exits while the
    /// next one is already running; with a single on/off task the old one's exit ended the new
    /// one's background time, iOS suspended the app mid-transfer, and the board was left with a few
    /// rows of the new song over the old picture. Every `hold` needs exactly one `release`.
    private var transferBackgroundHolds = 0

    /// Keeps the app running in the background until the matching `releaseTransferBackgroundTime()`.
    /// `SpotifyManager` takes one *before* launching a send task, so there is no gap between its own
    /// poll's background time ending and `processTrack` starting.
    func holdTransferBackgroundTime() {
        transferBackgroundHolds += 1
        guard transferBackgroundTaskID == .invalid else { return }
        transferBackgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "BLESpotifyArtTransfer") { [weak self] in
            // iOS is out of patience: end now regardless of holds (it kills the app otherwise).
            Task { @MainActor in
                guard let self else { return }
                self.transferBackgroundHolds = 0
                self.endTransferBackgroundTask()
            }
        }
    }

    func releaseTransferBackgroundTime() {
        guard transferBackgroundHolds > 0 else { return }
        transferBackgroundHolds -= 1
        if transferBackgroundHolds == 0 { endTransferBackgroundTask() }
    }

    private func endTransferBackgroundTask() {
        guard transferBackgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(transferBackgroundTaskID)
        transferBackgroundTaskID = .invalid
    }

    private func cancelImageSuccessTimeoutTask() {
        transferTimeoutGen &+= 1
        let t = imageSuccessTimeoutTask
        imageSuccessTimeoutTask = nil
        t?.cancel()
    }

    /// Shared path for a live connection (fresh connect or state restoration while already connected).
    private func enterConnectedStateAndDiscover(_ peripheral: CBPeripheral) {
        self.peripheral = peripheral
        peripheral.delegate = self
        isConnected = true
        sdCacheEntryCount = nil
        sdCacheCountLoading = true
        sawReady = false
        readyEpochCommittedForConnection = false
        statusMessage = "Discovering services…"
        peripheral.discoverServices([serviceUUID])
    }

    func startScanning() {
        guard central.state == .poweredOn else { return }
        statusMessage = "Scanning for Spotify Display…"
        central.scanForPeripherals(withServices: [serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    /// Cache-only check (same 20-byte packet as Python). On a hit the board draws the cover.
    /// `newSong`: the keychain has never shown this cover, so its status LED lights the new-song orange
    /// even when the cover is already on SD (queue prefetch). Older boards get the plain check.
    func checkCacheHit(cacheKey: Data, newSong: Bool = false) async throws -> Bool {
        let magic = newSong && boardSupportsNewSong ? cacheNewSongMagic : cacheMagic
        return try await sendCacheQuery(magic: magic, cacheKey: cacheKey)
    }

    /// Normal check (`cacheMagic`, draws on a hit) or prefetch probe (`cacheProbeMagic`, never draws).
    /// Both are answered with one byte on the Cache characteristic, so both count as an owed reply.
    private func sendCacheQuery(magic: UInt32, cacheKey: Data) async throws -> Bool {
        try ensureGattReady()
        guard let p = peripheral, let c = cacheChar else { throw SpotifyDisplayError.notConnected }

        cacheContinuation?.resume(throwing: CancellationError())
        cacheContinuation = nil

        var packet = Data()
        withUnsafeBytes(of: magic.littleEndian) { packet.append(contentsOf: $0) }
        packet.append(cacheKey)
        log("tx      cache \(magic == cacheProbeMagic ? "probe" : (magic == cacheNewSongMagic ? "check (new song)" : "check")) key=\(cacheKey.prefix(4).map { String(format: "%02x", $0) }.joined())…", kind: .tx)

        cacheCheckGen &+= 1
        let myGen = cacheCheckGen
        return try await withCheckedThrowingContinuation { cont in
            self.cacheContinuation = cont
            Task { @MainActor in
                // On a hit the firmware loads from SD and runs the full transition before replying;
                // per-pixel transitions can take several seconds.
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard self.cacheCheckGen == myGen, let pending = self.cacheContinuation else { return }
                self.cacheContinuation = nil
                pending.resume(throwing: SpotifyDisplayError.bleTimeout)
            }
            self.cacheReplyOwed = true
            p.writeValue(packet, for: c, type: .withResponse)
        }
    }

    /// Waits until the board has answered every cache check and finished every image this app sent,
    /// or until `boardIdleTimeoutNs` passes (then assumes the reply was lost and stops waiting).
    private func waitForBoardIdle() async {
        guard cacheReplyOwed || imageAckOwed else { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            boardIdleWaiters.append(c)
            boardIdleGen &+= 1
            let myGen = boardIdleGen
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: self.boardIdleTimeoutNs)
                guard self.boardIdleGen == myGen, !self.boardIdleWaiters.isEmpty else { return }
                self.cacheReplyOwed = false
                self.imageAckOwed = false
                self.resumeBoardIdleWaitersIfIdle()
            }
        }
    }

    private func resumeBoardIdleWaitersIfIdle() {
        guard !cacheReplyOwed, !imageAckOwed, !boardIdleWaiters.isEmpty else { return }
        let waiters = boardIdleWaiters
        boardIdleWaiters.removeAll()
        boardIdleGen &+= 1
        for w in waiters { w.resume() }
    }

    /// Aborts in-flight album download and BLE chunk loop. Next `processTrack` uses a fresh epoch; send a new image header on the next transfer so the ESP32 can resync if the previous send was partial.
    func cancelOngoingTransfer() {
        transferEpoch += 1
        cancelImageSuccessTimeoutTask()
        activeDownloadTask?.cancel()
        activeDownloadTask = nil
        cacheContinuation?.resume(throwing: CancellationError())
        cacheContinuation = nil
        transferContinuation?.resume(throwing: CancellationError())
        transferContinuation = nil
        cacheRenderContinuation?.resume(throwing: CancellationError())
        cacheRenderContinuation = nil
        awaitingCacheRenderConfirm = false
        cacheRenderConfirmed = false
        // Wake a chunk loop parked on the write window so it sees the new epoch and exits.
        writeDrainContinuation?.resume()
        writeDrainContinuation = nil
        // Deliberately NOT clearing cacheReplyOwed / imageAckOwed: the board still sends those replies.
        if isTransferring {
            isTransferring = false
            transferProgress = 0
        }
        // #region agent log
        AgentDebugLog.ingest(
            hypothesisId: "H2",
            location: "BLEManager.cancelOngoingTransfer",
            message: "cancel_incremented_epoch",
            data: ["transferEpoch": Int(transferEpoch)]
        )
        // #endregion agent log
    }

    private func ensureTransferEpoch(_ epochAtStart: UInt64) throws {
        if epochAtStart != transferEpoch {
            throw CancellationError()
        }
    }

    /// All-time totals (Settings > Lifetime stats), saved after every finished transfer.
    @Published private(set) var lifetime = LifetimeStats.load()

    func resetLifetimeStats() {
        lifetime = LifetimeStats()
        lifetime.save()
    }

    private func appendLog(_ entry: TransferLogEntry) {
        lifetime.record(entry)
        lifetime.save()
        transferLog.append(entry)
        if transferLog.count > maxLogEntries {
            transferLog.removeFirst(transferLog.count - maxLogEntries)
        }
    }

    private func setLivePhase(_ text: String?) {
        if let text, text != currentLivePhase { log("phase   \(text)", kind: .info) }
        currentLivePhase = text
    }

    /// Appends one line to the Live tab's terminal.
    func log(_ text: String, kind: LogLine.Kind) {
        eventLog.append(LogLine(kind: kind, text: text))
        if eventLog.count > maxLogLines {
            eventLog.removeFirst(eventLog.count - maxLogLines)
        }
    }

    /// Sends the person's enabled-transitions list to the board (BLE_PROTOCOL 1.12). Normally only
    /// boards that announced `CAPS:transitions` get it. `beforeCaps`: send anyway (right after READY,
    /// before the first cover is drawn and before the stats reply that carries `CAPS:` can arrive);
    /// older firmware just logs "Bad magic" and ignores it. The board never replies to this write, so
    /// it is not an owed cache reply.
    func applyTransitionPrefs(beforeCaps: Bool = false) {
        guard boardSupportsTransitionMask || beforeCaps, isConnected, let p = peripheral, let c = cacheChar else { return }
        let mask = TransitionPrefs.currentMask
        var packet = Data()
        withUnsafeBytes(of: transitionMaskMagic.littleEndian) { packet.append(contentsOf: $0) }
        // 1.13: low 64 bits, then the high 64 (bit 127 set) in what 1.12 called padding.
        withUnsafeBytes(of: mask.lo.littleEndian) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: mask.hi.littleEndian) { packet.append(contentsOf: $0) }
        p.writeValue(packet, for: c, type: .withResponse)
        let on = TransitionCatalog.all.filter { mask.contains($0.id) }.count
        log("tx      transition mask: \(on) of \(TransitionCatalog.all.count) on", kind: .tx)
        applyTransitionSpeeds()
    }

    /// Sends the per-transition speeds and the random-speed switch (BLE_PROTOCOL 1.14). Only to boards
    /// that announced `CAPS:speeds`: older firmware expects 20-byte cache writes. No reply.
    func applyTransitionSpeeds() {
        guard boardSupportsSpeeds, isConnected, let p = peripheral, let c = cacheChar else { return }
        let speeds = TransitionSpeeds.current
        let random = TransitionSpeeds.randomOn
        let slots = boardSupports128 ? TransitionSpeeds.slots128 : TransitionSpeeds.slots
        p.writeValue(TransitionSpeeds.packet(speeds: speeds, random: random, slots: slots), for: c, type: .withResponse)
        log("tx      transition speeds: \(speeds.count) custom, random \(random ? "on 0.4-1.3x" : "off"), \(slots) slots", kind: .tx)
    }

    /// Sends the pending swap flip (`flipNextDraw`) right before a draw request, so nothing drawn in
    /// between can use it. Boards without `CAPS:next` just draw their usual random transition.
    private func sendSwapFlipIfAsked() {
        guard flipNextDraw else { return }
        flipNextDraw = false
        guard boardSupportsNextTransition, isConnected, let p = peripheral, let c = cacheChar else { return }
        var packet = Data()
        withUnsafeBytes(of: nextTransitionMagic.littleEndian) { packet.append(contentsOf: $0) }
        packet.append(Self.swapFlipTransition)
        packet.append(Data(count: 15))
        p.writeValue(packet, for: c, type: .withResponse)
        log("tx      next draw: Card Flip (photo/cover swap)", kind: .tx)
    }

    /// Photo upload is over (or failed before the board drew it): let Spotify drive the display again.
    /// The caller asks `SpotifyManager.requestResync` afterwards to redraw the current song.
    func endPhotoHold() {
        guard photoHold else { return }
        photoHold = false
        log("photo   released, Spotify resumes", kind: .info)
    }

    /// Shows a user photo on the display. `jpeg` is already cropped square. Not saved to the SD cache
    /// (header byte 0xFD) and Spotify sends stay paused (`photoHold`) until `endPhotoHold()`.
    func sendPhoto(jpeg: Data) async throws {
        guard boardSupportsTransitionMask else {
            throw SpotifyDisplayError.bleTransferRejected("This display's firmware is too old for photo upload. Flash the latest firmware.")
        }
        lastPhotoJPEG = jpeg
        holdTransferBackgroundTime()
        defer { releaseTransferBackgroundTime() }
        let hadHold = photoHold
        photoHold = true
        cancelOngoingTransfer()
        if cacheReplyOwed || imageAckOwed { await waitForBoardIdle() }
        sendSwapFlipIfAsked()

        sendStageGen &+= 1
        let myStageGen = sendStageGen
        defer { if sendStageGen == myStageGen { sendStage = .idle } }
        let epochAtStart = transferEpoch
        let totalStart = CFAbsoluteTimeGetCurrent()
        do {
            sendStage = .preparingFresh
            currentAlbumArt = jpeg
            setLivePhase("photo: dithering…")
            let convertStart = CFAbsoluteTimeGetCurrent()
            let rgb565 = try await Task.detached(priority: .userInitiated) {
                try ImageProcessor.convertToRGB565(imageData: jpeg)
            }.value
            let convertMs = ms(since: convertStart)
            try ensureTransferEpoch(epochAtStart)
            guard rgb565.count == imagePayloadBytes else { throw SpotifyDisplayError.conversionFailed }

            let uploadStart = CFAbsoluteTimeGetCurrent()
            setLivePhase("photo: sending BLE…")
            _ = try await sendRGB565(rgb565, epochAtStart: epochAtStart, displayOnly: true)
            let uploadMs = ms(since: uploadStart)
            let totalMs = ms(since: totalStart)
            lastTransferResult = "Photo shown  \(secondsLabel(fromMs: totalMs))"
            boardAckStatus = "Board ACK: photo shown (not saved)"
            appendLog(TransferLogEntry(
                cacheHit: false, transitionName: lastTransitionName, cacheCheckMs: 0,
                downloadMs: nil, convertMs: convertMs, uploadMs: uploadMs,
                totalMs: totalMs, outcome: "photo"
            ))
            setLivePhase("last: photo \(secondsLabel(fromMs: totalMs))")
        } catch {
            if !hadHold { photoHold = false }
            throw error
        }
    }

    /// Clears top status badges so stale transfer state is hidden while the next track prepares.
    func clearTopTransferStatus() {
        lastTransferResult = nil
        boardAckStatus = nil
        lastTransitionName = nil
    }

    private func ms(since start: CFAbsoluteTime) -> Int {
        Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
    }

    private func secondsLabel(fromMs ms: Int) -> String {
        String(format: "%.1fs", Double(ms) / 1000.0)
    }

    /// Parallel download + cache check (like desktop script), then send on miss.
    /// `imageURLs` is ordered by preference; only the first two are attempted.
    func processTrack(imageURLs: [String], albumId: String?, trackId: String) async throws {
        holdTransferBackgroundTime()
        defer { releaseTransferBackgroundTime() }
        sendStageGen &+= 1
        let myStageGen = sendStageGen
        sendStage = .checking
        defer {
            if sendStageGen == myStageGen { sendStage = .idle }
        }
        setLivePhase("cache check + downloading…")
        boardAckStatus = "Sending…"

        let totalStart = CFAbsoluteTimeGetCurrent()
        let epochAtStart = transferEpoch
        try ensureTransferEpoch(epochAtStart)
        guard let primaryURL = imageURLs.first else { throw SpotifyDisplayError.conversionFailed }

        // Start download + cache check in parallel.
        let downloadStart = CFAbsoluteTimeGetCurrent()
        let download = Task { try await self.fetchAlbumArtData(urlCandidates: imageURLs) }
        activeDownloadTask = download
        // The cover as the board will show it: the frame to send on a miss, and on a hit the
        // same bytes as the SD copy (for the transition mirror and `boardFrame`). Converting as soon
        // as the download lands overlaps it with the cache check.
        let frameTask = Task<Data?, Never> {
            guard let data = try? await download.value else { return nil }
            return try? await Task.detached(priority: .userInitiated) {
                try ImageProcessor.convertToRGB565(imageData: data)
            }.value
        }

        // After a skip the board may still owe the previous song's cache reply or image ACK.
        // Asking now would get that old answer back as this song's; wait it out (download keeps going).
        if cacheReplyOwed || imageAckOwed {
            setLivePhase("waiting for display…")
            await waitForBoardIdle()
        }
        do {
            try ensureTransferEpoch(epochAtStart)
        } catch {
            download.cancel()
            throw error
        }

        let cacheCheckStart = CFAbsoluteTimeGetCurrent()
        setLivePhase("cache check + downloading…")
        let cacheHit: Bool
        let cacheKeySource = String.cacheKeySource(albumId: albumId, imageURL: primaryURL)
        let cacheKey = cacheKeySource.md5Digest
        // "Played before" is per album: the first song from an album is new (orange on the keychain)
        // even when its cover is already on the card (prefetched); later songs from it are blue.
        let albumKey = playKey(albumId: albumId, trackId: trackId)
        sendSwapFlipIfAsked()
        awaitingCacheRenderConfirm = true
        cacheRenderConfirmed = false
        noteDrawRequest(.cacheCheck(frameTask))
        let hitDrawGen = drawRequestGen
        do {
            cacheHit = try await checkCacheHit(cacheKey: cacheKey, newSong: !playedAlbumSet.contains(albumKey))
        } catch {
            awaitingCacheRenderConfirm = false
            cacheRenderConfirmed = false
            download.cancel()
            activeDownloadTask = nil
            throw error
        }
        let cacheCheckMs = ms(since: cacheCheckStart)
        setLivePhase("cache \(secondsLabel(fromMs: cacheCheckMs))")

        try ensureTransferEpoch(epochAtStart)

        if cacheHit {
            do {
                try await awaitCacheRenderConfirmation()
                // Cache hit confirmed — finish download in background for app preview only.
                let previewDownload = download
                activeDownloadTask = nil
                Task { @MainActor in
                    // Skip if a newer track started meanwhile: its art must not be replaced by ours.
                    if let data = try? await previewDownload.value, self.sendStageGen == myStageGen {
                        self.currentAlbumArt = data
                    }
                }
                Task { @MainActor in
                    if let frame = await frameTask.value, self.drawRequestGen == hitDrawGen {
                        self.boardFrame = frame
                    }
                }
                statusMessage = "Loaded from SD cache"
                let totalMs = ms(since: totalStart)
                setLivePhase("cache hit \(secondsLabel(fromMs: totalMs))")
                lastTransferResult = "Cache hit  \(secondsLabel(fromMs: totalMs))"
                boardAckStatus = "Board ACK: cache hit"
                lastConfirmedTrackId = trackId
                let wasPrefetched = prefetchedKeySources.remove(cacheKeySource) != nil
                // First song from this album: "new", although its cover came off the card.
                let firstShow = markAlbumPlayed(albumKey)
                appendLog(TransferLogEntry(
                    cacheHit: true, transitionName: lastTransitionName, cacheCheckMs: cacheCheckMs,
                    downloadMs: nil, convertMs: nil, uploadMs: 0,
                    totalMs: totalMs, outcome: "cache hit",
                    prefetched: wasPrefetched ? true : nil,
                    firstShow: firstShow ? true : nil
                ))
                setLivePhase("last: cache hit \(secondsLabel(fromMs: totalMs))")
                return
            } catch {
                // Cache render confirmation failed — fall through to fresh BLE send.
                setLivePhase("cache render failed, sending fresh…")
            }
        }
        awaitingCacheRenderConfirm = false
        cacheRenderConfirmed = false

        let data: Data
        setLivePhase("waiting download…")
        do {
            data = try await download.value
        } catch {
            activeDownloadTask = nil
            throw error
        }
        activeDownloadTask = nil
        let downloadMs = ms(since: downloadStart)
        setLivePhase("download \(secondsLabel(fromMs: downloadMs))")

        try ensureTransferEpoch(epochAtStart)

        // Set before the art so the preview sees "fresh send coming" when the new cover lands.
        sendStage = .preparingFresh
        currentAlbumArt = data

        statusMessage = "Processing image…"
        setLivePhase("dithering…")
        let convertStart = CFAbsoluteTimeGetCurrent()
        // Usually done already: it started when the download finished (see `frameTask`).
        let converted = await frameTask.value
        let convertMs = ms(since: convertStart)
        setLivePhase("dither \(secondsLabel(fromMs: convertMs))")
        try ensureTransferEpoch(epochAtStart)

        guard let rgb565 = converted, rgb565.count == imagePayloadBytes else {
            throw SpotifyDisplayError.conversionFailed
        }

        let uploadStart = CFAbsoluteTimeGetCurrent()
        setLivePhase("sending BLE…")
        let wireBytes = try await sendRGB565(rgb565, epochAtStart: epochAtStart)
        let uploadMs = ms(since: uploadStart)
        let wireLabel = "\(wireBytes / 1024) KB" + (wireBytes < rgb565.count
            ? String(format: ", %.1f×", Double(rgb565.count) / Double(wireBytes)) : "")
        setLivePhase("sent \(wireLabel) in \(secondsLabel(fromMs: uploadMs))")

        let totalMs = ms(since: totalStart)
        setLivePhase("done \(secondsLabel(fromMs: totalMs))")
        lastTransferResult = "Sent new  \(secondsLabel(fromMs: totalMs)) (dl \(secondsLabel(fromMs: downloadMs)), \(wireLabel))"
        boardAckStatus = "Board ACK: image sent"
        lastConfirmedTrackId = trackId
        markAlbumPlayed(albumKey)
        appendLog(TransferLogEntry(
            cacheHit: false, transitionName: lastTransitionName, cacheCheckMs: cacheCheckMs,
            downloadMs: downloadMs, convertMs: convertMs, uploadMs: uploadMs,
            totalMs: totalMs, outcome: "ok"
        ))
        setLivePhase("last: done \(secondsLabel(fromMs: totalMs))")
    }

    private static let artDownloadSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        return URLSession(configuration: config)
    }()

    private func fetchAlbumArtData(urlCandidates: [String]) async throws -> Data {
        var firstError: Error?
        for candidate in urlCandidates.prefix(2) {
            guard let url = URL(string: candidate) else { continue }
            do {
                let (data, response) = try await Self.artDownloadSession.data(from: url)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    throw URLError(.badServerResponse)
                }
                guard UIImage(data: data) != nil else {
                    throw SpotifyDisplayError.conversionFailed
                }
                return data
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        throw firstError ?? SpotifyDisplayError.conversionFailed
    }

    private func awaitCacheRenderConfirmation() async throws {
        if cacheRenderConfirmed {
            awaitingCacheRenderConfirm = false
            cacheRenderConfirmed = false
            return
        }
        cacheRenderGen &+= 1
        let myGen = cacheRenderGen
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.cacheRenderContinuation = cont
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard self.cacheRenderGen == myGen, let pending = self.cacheRenderContinuation else { return }
                self.cacheRenderContinuation = nil
                self.awaitingCacheRenderConfirm = false
                self.cacheRenderConfirmed = false
                pending.resume(throwing: SpotifyDisplayError.bleTransferRejected("ERROR: Cache render confirmation missing"))
            }
        }
        awaitingCacheRenderConfirm = false
        cacheRenderConfirmed = false
    }

    /// `storeOnly` (prefetch): the board saves the frame to SD without drawing it, and this call leaves
    /// every piece of UI state (progress, status text, live phase) alone.
    /// Returns the bytes that went over the air (smaller than `rgb565` when sent compressed).
    @discardableResult
    func sendRGB565(_ rgb565: Data, epochAtStart: UInt64, storeOnly: Bool = false, displayOnly: Bool = false) async throws -> Int {
        try ensureTransferEpoch(epochAtStart)
        try ensureGattReady()
        guard let p = peripheral, let img = imageChar else { throw SpotifyDisplayError.notConnected }

        awaitingImageComplete = true
        defer { awaitingImageComplete = false }

        transferContinuation?.resume(throwing: CancellationError())
        transferContinuation = nil

        try ensureTransferEpoch(epochAtStart)

        // BLE_PROTOCOL 1.11: deflate the frame when the board can inflate it. A few ms off-main.
        var packed: Data?
        if boardSupportsDeflate {
            let raw = rgb565
            packed = await Task.detached(priority: .userInitiated) { ImageProcessor.deflateRaw(raw) }.value
            if let pk = packed, Double(pk.count) > Double(rgb565.count) * minDeflateSaving { packed = nil }
            try ensureTransferEpoch(epochAtStart)
        }
        let payload = packed ?? rgb565

        // A frame the board will draw (not a prefetch): its TRANSITION_START will be for these bytes.
        var myDrawGen: UInt64 = 0
        if !storeOnly {
            noteDrawRequest(.image(rgb565))
            myDrawGen = drawRequestGen
        }

        var header = Data()
        // 0xFF = random (enabled) transition on firmware; 0xFE store-only; 0xFD display-only (photo)
        header.append(storeOnly ? storeOnlyTransition : (displayOnly ? displayOnlyTransition : 0xFF))
        if packed != nil {
            header.append(deflateFormat)
            withUnsafeBytes(of: UInt32(imagePayloadBytes).littleEndian) { header.append(contentsOf: $0) }
            withUnsafeBytes(of: UInt32(payload.count).littleEndian) { header.append(contentsOf: $0) }
        } else {
            withUnsafeBytes(of: UInt32(imagePayloadBytes).littleEndian) { header.append(contentsOf: $0) }
        }
        p.writeValue(header, for: img, type: .withResponse)
        if !storeOnly {
            log("tx      image header (\(displayOnly ? "photo, no SD save" : "random transition")), \(payload.count / 1024) KB\(packed != nil ? " deflated" : " raw")", kind: .tx)
        }

        try ensureTransferEpoch(epochAtStart)

        if !storeOnly {
            isTransferring = true
            transferProgress = 0
        }

        let total = payload.count
        var offset = 0
        let useWithoutResponse = img.properties.contains(.writeWithoutResponse)
        let mtuWR = p.maximumWriteValueLength(for: .withoutResponse)
        let writeChunkSize = useWithoutResponse
            ? min(chunkSize, mtuWR > 0 ? mtuWR : chunkSize)
            : chunkSize

        while offset < total {
            try ensureTransferEpoch(epochAtStart)
            if useWithoutResponse {
                await awaitWriteWindow(peripheral: p, epochAtStart: epochAtStart)
            }
            try ensureTransferEpoch(epochAtStart)
            let end = min(offset + writeChunkSize, total)
            let chunk = payload.subdata(in: offset..<end)
            let wtype: CBCharacteristicWriteType = useWithoutResponse ? .withoutResponse : .withResponse
            p.writeValue(chunk, for: img, type: wtype)
            offset = end
            if !storeOnly { transferProgress = Double(offset) / Double(total) }
            if !useWithoutResponse {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }

        try ensureTransferEpoch(epochAtStart)

        // Every byte is queued: the board will draw, save and ACK this frame even if we skip now.
        imageAckOwed = true

        // #region agent log
        AgentDebugLog.ingest(
            hypothesisId: "H1",
            location: "BLEManager.sendRGB565",
            message: "installing_success_wait",
            data: ["epochAtStart": Int(epochAtStart), "transferEpoch": Int(transferEpoch)]
        )
        // #endregion agent log

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.transferContinuation = cont
            self.cancelImageSuccessTimeoutTask()
            self.transferTimeoutGen &+= 1
            let myGen = self.transferTimeoutGen
            self.imageSuccessTimeoutTask = Task { @MainActor in
                // Only clear the slot if it is still ours: a cancelled older task exiting here used to
                // nil out the newer task, which then could not be cancelled and fired against a later transfer.
                defer {
                    if self.transferTimeoutGen == myGen { self.imageSuccessTimeoutTask = nil }
                }
                do {
                    // Firmware ACK after progressive draw + SD save; typically <2s.
                    try await Task.sleep(nanoseconds: 8_000_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled, self.transferTimeoutGen == myGen else { return }
                if let c = self.transferContinuation {
                    // #region agent log
                    AgentDebugLog.ingest(
                        hypothesisId: "H1",
                        location: "BLEManager.sendRGB565.timeoutTask",
                        message: "bleTimeout_firing",
                        data: ["transferEpoch": Int(self.transferEpoch)]
                    )
                    // #endregion agent log
                    self.transferContinuation = nil
                    c.resume(throwing: SpotifyDisplayError.bleTimeout)
                }
            }
        }

        // #region agent log
        AgentDebugLog.ingest(
            hypothesisId: "H1",
            location: "BLEManager.sendRGB565",
            message: "success_wait_completed_normally",
            data: ["transferEpoch": Int(transferEpoch)]
        )
        // #endregion agent log

        cancelImageSuccessTimeoutTask()

        try ensureTransferEpoch(epochAtStart)

        // The board ACKs only after its SD save, so a saved frame (everything but a photo) is one more
        // cover on the card right now: bump the count at once, prefetches included (they otherwise
        // never refreshed it). The board's own count, read after every drawn frame and on reconnect,
        // corrects it if a save didn't add a file.
        if !displayOnly, let n = sdCacheEntryCount {
            sdCacheEntryCount = n + 1
        }
        if storeOnly { return total }
        log("rx      image ACK", kind: .rx)
        if drawRequestGen == myDrawGen { boardFrame = rgb565 }

        isTransferring = false
        transferProgress = 0
        statusMessage = "Sent to display"
        setLivePhase("idle")

        Task { @MainActor in
            try? await self.refreshSDCacheCount()
        }
        return total
    }

    enum PrefetchOutcome { case alreadyCached, stored, noArt }

    /// Puts the cover of a song that is NOT playing yet on the board's SD card, so that when it starts
    /// its cache check is a hit (~1.5 s instead of ~4 s). Never draws, never touches the preview art
    /// or status UI. A real track change calls `cancelOngoingTransfer()`, which bumps the epoch and
    /// aborts this at its next check; the board drops a partial frame on the next cache check.
    func prefetchTrack(imageURLs: [String], albumId: String?) async throws -> PrefetchOutcome {
        holdTransferBackgroundTime()
        defer { releaseTransferBackgroundTime() }
        let epochAtStart = transferEpoch
        guard let primaryURL = imageURLs.first else { return .noArt }

        if cacheReplyOwed || imageAckOwed { await waitForBoardIdle() }
        try ensureTransferEpoch(epochAtStart)

        let keySource = String.cacheKeySource(albumId: albumId, imageURL: primaryURL)
        let cacheKey = keySource.md5Digest
        if try await sendCacheQuery(magic: cacheProbeMagic, cacheKey: cacheKey) { return .alreadyCached }
        try ensureTransferEpoch(epochAtStart)

        let download = Task { try await self.fetchAlbumArtData(urlCandidates: imageURLs) }
        activeDownloadTask = download
        let data: Data
        do {
            data = try await download.value
        } catch {
            if activeDownloadTask == download { activeDownloadTask = nil }
            throw error
        }
        if activeDownloadTask == download { activeDownloadTask = nil }
        try ensureTransferEpoch(epochAtStart)

        let rgb565 = try await Task.detached(priority: .utility) {
            try ImageProcessor.convertToRGB565(imageData: data)
        }.value
        try ensureTransferEpoch(epochAtStart)
        guard rgb565.count == imagePayloadBytes else { throw SpotifyDisplayError.conversionFailed }

        _ = try await sendRGB565(rgb565, epochAtStart: epochAtStart, storeOnly: true)
        prefetchedKeySources.insert(keySource)
        return .stored
    }

    /// Ask ESP32 (firmware with stats magic) how many `.bin` files are in `/cache`.
    func refreshSDCacheCount() async throws {
        try ensureGattReady()
        guard let p = peripheral, let c = cacheChar else { throw SpotifyDisplayError.notConnected }

        statsContinuation?.resume(throwing: CancellationError())
        statsContinuation = nil

        var packet = Data()
        withUnsafeBytes(of: statsMagic.littleEndian) { packet.append(contentsOf: $0) }
        packet.append(Data(count: 16))

        statsCheckGen &+= 1
        let myGen = statsCheckGen
        let count = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int, Error>) in
            self.statsContinuation = cont
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard self.statsCheckGen == myGen, let c = self.statsContinuation else { return }
                self.statsContinuation = nil
                c.resume(throwing: SpotifyDisplayError.bleTimeout)
            }
            p.writeValue(packet, for: c, type: .withResponse)
        }
        sdCacheEntryCount = count
    }

    private func ensureGattReady() throws {
        guard isConnected, statusChar != nil, cacheChar != nil, imageChar != nil, msgChar != nil, brightnessChar != nil else {
            throw SpotifyDisplayError.notConnected
        }
    }

    private func resetGattState() {
        statusChar = nil
        cacheChar = nil
        imageChar = nil
        msgChar = nil
        brightnessChar = nil
        statusLedChar = nil
        boardSupportsStatusLed = false
        sawReady = false
        boardSupportsDeflate = false
        boardSupportsTransitionMask = false
        boardSupportsSpeeds = false
        boardSupports128 = false
        boardSupportsNextTransition = false
        boardSupportsNewSong = false
        flipNextDraw = false
        photoHold = false  // the board resets to its waiting screen on disconnect; the photo is gone
        // Waiting screen: nothing of ours is on the panel any more.
        boardFrame = nil
        lastDrawRequest = nil
        drawRequestGen &+= 1
        transitionStart = nil
        mirror.reset()
        failPending(error: SpotifyDisplayError.notConnected)
    }

    private func failPending(error: Error) {
        transferEpoch += 1
        cancelImageSuccessTimeoutTask()
        activeDownloadTask?.cancel()
        activeDownloadTask = nil
        readyContinuation?.resume(throwing: error)
        readyContinuation = nil
        cacheContinuation?.resume(throwing: error)
        cacheContinuation = nil
        transferContinuation?.resume(throwing: error)
        transferContinuation = nil
        cacheRenderContinuation?.resume(throwing: error)
        cacheRenderContinuation = nil
        awaitingCacheRenderConfirm = false
        cacheRenderConfirmed = false
        statsContinuation?.resume(throwing: error)
        statsContinuation = nil
        clearContinuation?.resume(throwing: error)
        clearContinuation = nil
        writeDrainContinuation?.resume()
        writeDrainContinuation = nil
        // Disconnected: the board's pending replies will never arrive.
        cacheReplyOwed = false
        imageAckOwed = false
        resumeBoardIdleWaitersIfIdle()
        if isTransferring {
            isTransferring = false
            transferProgress = 0
        }
    }

    /// Parks the chunk loop until CoreBluetooth can take another write-without-response.
    /// `peripheralIsReady` arrives via a main-actor hop, so it can land before the continuation is
    /// installed and be lost; the 100 ms re-check bounds that stall. Exits when the epoch changes.
    private func awaitWriteWindow(peripheral: CBPeripheral, epochAtStart: UInt64) async {
        while !peripheral.canSendWriteWithoutResponse, epochAtStart == transferEpoch {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                // Never overwrite a parked waiter (that leaks it and hangs its task forever).
                self.writeDrainContinuation?.resume()
                self.writeDrainContinuation = c
                self.writeDrainGen &+= 1
                let myGen = self.writeDrainGen
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    guard self.writeDrainGen == myGen, let pending = self.writeDrainContinuation else { return }
                    self.writeDrainContinuation = nil
                    pending.resume()
                }
            }
        }
    }

    private func signalReady() {
        sawReady = true
        if let c = readyContinuation {
            readyContinuation = nil
            c.resume()
        }
    }

    private func waitForReady() async throws {
        if sawReady { return }
        readyCheckGen &+= 1
        let myGen = readyCheckGen
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.readyContinuation = cont
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                guard self.readyCheckGen == myGen, let c = self.readyContinuation else { return }
                self.readyContinuation = nil
                c.resume(throwing: SpotifyDisplayError.bleTimeout)
            }
        }
    }

    private func handleMessage(_ text: String) {
        if text == "HB" {
            onHeartbeat?()
            return
        }
        if text.hasPrefix("ERROR") {
            log("rx      \(text)", kind: .error)
        } else if text.hasPrefix("TRANSITION:") || text.hasPrefix(TransitionStartEvent.prefix) {
            log("rx      \(text)", kind: .transition)
        } else {
            log("rx      \(text)", kind: .rx)
        }
        if text == "READY" { signalReady() }
        if text == "CAPS:deflate" { boardSupportsDeflate = true }
        if text == "CAPS:transitions" {
            // The board repeats this on every stats reply (the app asks after each send): act on the first.
            let firstTime = !boardSupportsTransitionMask
            boardSupportsTransitionMask = true
            if firstTime { applyTransitionPrefs() }
        }
        if text == "CAPS:speeds" {
            let firstTime = !boardSupportsSpeeds
            boardSupportsSpeeds = true
            if firstTime { applyTransitionSpeeds() }
        }
        if text == "CAPS:next" { boardSupportsNextTransition = true }
        if text == "CAPS:newsong" { boardSupportsNewSong = true }
        if text == "CAPS:t128" {
            // Arrives after CAPS:speeds: send the speeds again, now for every index.
            let firstTime = !boardSupports128
            boardSupports128 = true
            if firstTime { applyTransitionSpeeds() }
        }
        if text.hasPrefix("ERROR: Decompress") {
            // The retry (and every later frame this connection) goes raw.
            boardSupportsDeflate = false
        }

        // Firmware ERROR: replies reject the frame and reset its receive state; no ACK will follow.
        if text.hasPrefix("ERROR:") {
            imageAckOwed = false
            resumeBoardIdleWaitersIfIdle()
        }

        if text == "SUCCESS", awaitingImageComplete {
            if let c = transferContinuation {
                // #region agent log
                AgentDebugLog.ingest(
                    hypothesisId: "H5",
                    location: "BLEManager.handleMessage",
                    message: "notify_SUCCESS_msg_char",
                    data: ["hadContinuation": true]
                )
                // #endregion agent log
                transferContinuation = nil
                cancelImageSuccessTimeoutTask()
                c.resume()
            }
        }

        if (text == "CACHE_RENDERED" || text == "SUCCESS"), awaitingCacheRenderConfirm {
            cacheRenderConfirmed = true
            if let c = cacheRenderContinuation {
                cacheRenderContinuation = nil
                c.resume()
            }
        }

        if text.hasPrefix("ERROR:"), awaitingImageComplete, let c = transferContinuation {
            // #region agent log
            AgentDebugLog.ingest(
                hypothesisId: "H5",
                location: "BLEManager.handleMessage",
                message: "notify_ERROR_msg_char",
                data: ["prefix": String(text.prefix(48))]
            )
            // #endregion agent log
            transferContinuation = nil
            cancelImageSuccessTimeoutTask()
            c.resume(throwing: SpotifyDisplayError.bleTransferRejected(String(text)))
            return
        }

        if text.hasPrefix("CACHE_COUNT:") {
            let rest = text.dropFirst("CACHE_COUNT:".count)
            let trimmed = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            if let n = Int(trimmed) {
                sdCacheEntryCount = n
                if let c = statsContinuation {
                    statsContinuation = nil
                    c.resume(returning: n)
                }
            } else if let c = statsContinuation {
                statsContinuation = nil
                c.resume(throwing: SpotifyDisplayError.conversionFailed)
            }
        }

        if text == "CACHE_CLEARED", let c = clearContinuation {
            clearContinuation = nil
            c.resume()
        }

        if text.hasPrefix("TRANSITION:") {
            let t = text.dropFirst("TRANSITION:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty {
                lastTransitionName = t
                transitionEvent = TransitionEvent(name: t)
            }
        }

        if text.hasPrefix(TransitionStartEvent.prefix) {
            handleTransitionStart(text)
        }
    }

    /// Remembers what the board was just asked to draw (see `DrawRequest`).
    private func noteDrawRequest(_ request: DrawRequest) {
        lastDrawRequest = request
        drawRequestGen &+= 1
    }

    /// `TRANSITION_START:<index>:<seed>:<expectedMs>:<oldBlack>`: the board starts drawing now.
    /// Publishes the event and starts the cover mirror from the board's current frame.
    private func handleTransitionStart(_ text: String) {
        guard var event = TransitionStartEvent.parse(text) else {
            log("rx      unreadable \(text)", kind: .error)
            return
        }
        let old: Data? = event.oldBlack ? nil : boardFrame
        let request = lastDrawRequest
        lastDrawRequest = nil  // one request, one draw
        let gen = drawRequestGen
        switch request {
        case .image(let frame)?:
            event.newFrame = frame
            boardFrame = frame
        case .cacheCheck(let frameTask)?:
            // Hit: the cover is still downloading / converting; hand it over when ready.
            let id = event.id
            Task { @MainActor in
                guard let frame = await frameTask.value else { return }
                if self.drawRequestGen == gen { self.boardFrame = frame }
                if self.transitionStart?.id == id {
                    self.transitionStart?.newFrame = frame
                    self.mirror.provideFrame(frame, for: id)
                }
            }
        case nil:
            break  // not something this app asked for: nothing to mirror
        }
        transitionStart = event
        mirror.begin(event, old: old)
    }

    private func onCharacteristicsReady() async {
        guard let p = peripheral else { return }
        for ch in [statusChar, cacheChar, imageChar, msgChar].compactMap({ $0 }) {
            p.setNotifyValue(true, for: ch)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        // Firmware notifies READY in onConnect, before we have subscribed, so that notify is lost.
        // The status characteristic is readable and holds 0x01 while connected; read it instead.
        if let status = statusChar {
            p.readValue(for: status)
        }
        do {
            try await waitForReady()
            if !readyEpochCommittedForConnection {
                readyEpoch &+= 1
                readyEpochCommittedForConnection = true
            }
            statusMessage = "Ready"
            // Re-apply persisted brightness value on every reconnect.
            setBrightness(brightness)
            setStatusLedLevel(statusLedLevel)
            // The board's mask resets to all-on at boot. Send ours before the resync below draws the
            // first cover (writes on one characteristic are handled in order, so the board has the
            // mask before that cache check). The CAPS:transitions handler sends it again later.
            applyTransitionPrefs(beforeCaps: true)
            // Trigger immediate SpotifyManager resync — works even if app is in background.
            onReadyCallback?()
            defer { sdCacheCountLoading = false }
            try await refreshSDCacheCount()
        } catch {
            statusMessage = "Connected (READY timed out — check ESP32)"
            sdCacheCountLoading = false
        }
    }
}

extension BLEManager: CBCentralManagerDelegate {
    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        Task { @MainActor in
            guard let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral], !peripherals.isEmpty else {
                return
            }
            let named = peripherals.first { $0.name == "Spotify Display" }
            self.pendingRestoredPeripheral = named ?? peripherals.first
        }
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            if central.state == .poweredOn {
                if let p = self.pendingRestoredPeripheral {
                    self.pendingRestoredPeripheral = nil
                    self.applyRestoredPeripheral(p, central: central)
                    return
                }
                let connecting = self.peripheral?.state == .connecting
                if !self.isConnected, !connecting {
                    self.startScanning()
                }
            } else {
                self.statusMessage = "Bluetooth unavailable"
            }
        }
    }

    /// After state restoration: reconnect if needed, or rediscover services if already connected.
    private func applyRestoredPeripheral(_ p: CBPeripheral, central: CBCentralManager) {
        switch p.state {
        case .connected:
            statusMessage = "Restoring connection…"
            enterConnectedStateAndDiscover(p)
        case .disconnected:
            peripheral = p
            p.delegate = self
            isConnected = false
            statusMessage = "Reconnecting…"
            central.connect(p, options: nil)
        case .connecting:
            peripheral = p
            p.delegate = self
            statusMessage = "Connecting…"
        case .disconnecting:
            peripheral = p
            p.delegate = self
            statusMessage = "Disconnecting…"
        @unknown default:
            peripheral = p
            p.delegate = self
            statusMessage = "Connecting…"
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        Task { @MainActor in
            // Name may arrive only in the scan response (firmware uses setScanResponse), so check both.
            guard peripheral.name == "Spotify Display" || advertisedName == "Spotify Display" else { return }
            self.statusMessage = "Connecting…"
            self.peripheral = peripheral
            central.stopScan()
            central.connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.enterConnectedStateAndDiscover(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            self.statusMessage = "Connect failed"
            self.startScanning()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            self.isConnected = false
            self.readyEpochCommittedForConnection = false
            self.sdCacheEntryCount = nil
            self.sdCacheCountLoading = false
            self.resetGattState()
            self.statusMessage = "Disconnected — retrying…"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.startScanning()
            }
        }
    }
}

extension BLEManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard let services = peripheral.services else { return }
            for s in services where s.uuid == self.serviceUUID {
                peripheral.discoverCharacteristics(
                    [self.statusUUID, self.cacheUUID, self.imageUUID, self.messageUUID, self.brightnessUUID,
                     self.statusLedUUID],
                    for: s
                )
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            guard let chars = service.characteristics else { return }
            for ch in chars {
                switch ch.uuid {
                case self.statusUUID: self.statusChar = ch
                case self.cacheUUID: self.cacheChar = ch
                case self.imageUUID: self.imageChar = ch
                case self.messageUUID: self.msgChar = ch
                case self.brightnessUUID: self.brightnessChar = ch
                case self.statusLedUUID:
                    self.statusLedChar = ch
                    self.boardSupportsStatusLed = true
                default: break
                }
            }
            if self.statusChar != nil, self.cacheChar != nil, self.imageChar != nil, self.msgChar != nil, self.brightnessChar != nil {
                Task { await self.onCharacteristicsReady() }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        // Copy the value NOW. `characteristic.value` is the characteristic's *latest* value: the
        // board sends several Message notifies back-to-back (CACHE_HIT_MS, TRANSITION, CACHE_RENDERED,
        // SUCCESS, plus HB every second), and reading it inside the Task below returned whichever
        // arrived last. CACHE_RENDERED and SUCCESS were lost that way, causing bogus "render
        // confirmation missing" re-sends and 8 s SUCCESS timeouts. Callbacks arrive in order on the
        // main queue, so per-callback copies keep every message.
        guard error == nil, let data = characteristic.value else { return }
        let uuid = characteristic.uuid
        Task { @MainActor in
            switch uuid {
            case self.statusUUID:
                if data.count == 1, data[0] == 0x01 { self.signalReady() }

            case self.cacheUUID:
                guard data.count == 1 else { break }
                // Only one check is ever owed (processTrack waits before asking again), so this reply
                // belongs to the pending continuation, or to a check the app already gave up on.
                self.cacheReplyOwed = false
                if let c = self.cacheContinuation {
                    self.cacheContinuation = nil
                    c.resume(returning: data[0] == 0x01)
                }
                self.resumeBoardIdleWaitersIfIdle()

            case self.imageUUID:
                if data.count == 1, data[0] == 0x01 || data[0] == 0x02 {
                    self.imageAckOwed = false
                    self.resumeBoardIdleWaitersIfIdle()
                }
                if data.count == 1, self.awaitingImageComplete, let c = self.transferContinuation {
                    switch data[0] {
                    case 0x01:
                        // #region agent log
                        AgentDebugLog.ingest(
                            hypothesisId: "H5",
                            location: "BLEManager.didUpdateValue.image",
                            message: "notify_image_0x01_ok",
                            data: [:]
                        )
                        // #endregion agent log
                        self.transferContinuation = nil
                        self.cancelImageSuccessTimeoutTask()
                        c.resume()
                    case 0x02:
                        // #region agent log
                        AgentDebugLog.ingest(
                            hypothesisId: "H5",
                            location: "BLEManager.didUpdateValue.image",
                            message: "notify_image_0x02_err",
                            data: [:]
                        )
                        // #endregion agent log
                        self.transferContinuation = nil
                        self.cancelImageSuccessTimeoutTask()
                        c.resume(throwing: SpotifyDisplayError.bleTransferRejected("Display reported transfer error (0x02)"))
                    default:
                        break
                    }
                }

            case self.messageUUID:
                if let text = String(data: data, encoding: .utf8) {
                    self.handleMessage(text)
                }

            default:
                break
            }
        }
    }

    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        Task { @MainActor in
            self.writeDrainContinuation?.resume()
            self.writeDrainContinuation = nil
        }
    }
}

extension BLEManager {
    func setBrightness(_ value: UInt8) {
        brightness = value
        UserDefaults.standard.set(Int(value), forKey: "ble_brightness")
        guard let p = peripheral, let c = brightnessChar else { return }
        var b = value
        let payload = Data(bytes: &b, count: 1)
        p.writeValue(payload, for: c, type: .withResponse)
    }

    /// Status LED brightness, 0...255 of the board's safe cap (BLE_PROTOCOL 1.13). Saved, then sent
    /// if the board has the characteristic; otherwise it is sent on the next connect to newer firmware.
    func setStatusLedLevel(_ value: UInt8) {
        statusLedLevel = value
        UserDefaults.standard.set(Int(value), forKey: "ble_status_led")
        guard let p = peripheral, let c = statusLedChar else { return }
        var b = value
        let payload = Data(bytes: &b, count: 1)
        p.writeValue(payload, for: c, type: .withResponse)
    }

    func clearDisplayCache() async throws {
        try ensureGattReady()
        guard let p = peripheral, let c = cacheChar else { throw SpotifyDisplayError.notConnected }
        clearContinuation?.resume(throwing: CancellationError())
        clearContinuation = nil
        var packet = Data()
        withUnsafeBytes(of: UInt32(0xCAC4E1EA).littleEndian) { packet.append(contentsOf: $0) }
        packet.append(Data(count: 16))
        clearCheckGen &+= 1
        let myGen = clearCheckGen
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.clearContinuation = cont
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard self.clearCheckGen == myGen, let pending = self.clearContinuation else { return }
                self.clearContinuation = nil
                pending.resume(throwing: SpotifyDisplayError.bleTimeout)
            }
            p.writeValue(packet, for: c, type: .withResponse)
        }
        try await refreshSDCacheCount()
    }
}

