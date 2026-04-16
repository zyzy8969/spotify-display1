import SwiftUI
import CoreBluetooth
import UIKit

/// ESP32 GATT contract — repo `spotify-display1`: `docs/BLE_PROTOCOL.md`, `src/main.cpp`, `python/spotify_album_sender.py`.
@MainActor
final class BLEManager: NSObject, ObservableObject {
    @Published private(set) var isConnected = false
    @Published var currentAlbumArt: Data?
    @Published var statusMessage = "Bluetooth…"
    @Published var isTransferring = false
    @Published var transferProgress: Double = 0
    /// Total `.bin` files in `/cache` on the display (from stats / `CACHE_COUNT:`). `nil` until first successful read this connection.
    @Published private(set) var sdCacheEntryCount: Int?
    /// True after connect until the first post-`READY` cache stats request finishes (success or failure).
    @Published private(set) var sdCacheCountLoading = false
    /// Increments whenever GATT is fully ready after (re)connect; consumers can use this as a sync session token.
    @Published private(set) var readyEpoch: UInt64 = 0
    @Published var brightness: UInt8 = UInt8(clamping: UserDefaults.standard.integer(forKey: "ble_brightness"))
    @Published private(set) var transferLog: [TransferLogEntry] = []
    @Published private(set) var currentLivePhase: String? = "idle"
    /// Shows "Cache hit" / "Sent to display" / nil on main screen.
    @Published private(set) var lastTransferResult: String?
    /// Human-readable board confirmation for latest transfer stage.
    @Published private(set) var boardAckStatus: String?
    /// Track id most recently confirmed on-board (cache hit draw or BLE SUCCESS).
    @Published private(set) var lastConfirmedTrackId: String?
    private let maxLogEntries = 30

    /// Called on MainActor when GATT is fully ready after (re)connect. SpotifyManager registers this for instant resync.
    var onReadyCallback: (() -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var statusChar: CBCharacteristic?
    private var cacheChar: CBCharacteristic?
    private var imageChar: CBCharacteristic?
    private var msgChar: CBCharacteristic?
    private var brightnessChar: CBCharacteristic?

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

    private var sawReady = false
    /// Ensures `readyEpoch` increments at most once per BLE connection even if characteristics discovery runs more than once.
    private var readyEpochCommittedForConnection = false
    private var awaitingImageComplete = false
    private var awaitingCacheRenderConfirm = false
    private var cacheRenderConfirmed = false
    /// Last transition announced by firmware via `MESSAGE` notify (`TRANSITION:<name>`).
    @Published private(set) var lastTransitionName: String?

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

    /// Same as firmware `IMAGE_SIZE` (240×240×2).
    private let imagePayloadBytes = 115_200
    private let chunkSize = 512
    private let cacheMagic = UInt32(0xDEADBEEF)
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

    private func beginTransferBackgroundTaskIfNeeded() {
        guard transferBackgroundTaskID == .invalid else { return }
        transferBackgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "BLESpotifyArtTransfer") { [weak self] in
            Task { @MainActor in self?.endTransferBackgroundTaskIfNeeded() }
        }
    }

    private func endTransferBackgroundTaskIfNeeded() {
        guard transferBackgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(transferBackgroundTaskID)
        transferBackgroundTaskID = .invalid
    }

    private func cancelImageSuccessTimeoutTask() {
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

    /// Cache-only check (same 20-byte packet as Python).
    func checkCacheHit(cacheKey: Data) async throws -> Bool {
        try ensureGattReady()
        guard let p = peripheral, let c = cacheChar else { throw SpotifyDisplayError.notConnected }

        cacheContinuation?.resume(throwing: CancellationError())
        cacheContinuation = nil

        var packet = Data()
        withUnsafeBytes(of: cacheMagic.littleEndian) { packet.append(contentsOf: $0) }
        packet.append(cacheKey)

        cacheCheckGen &+= 1
        let myGen = cacheCheckGen
        return try await withCheckedThrowingContinuation { cont in
            self.cacheContinuation = cont
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard self.cacheCheckGen == myGen, let pending = self.cacheContinuation else { return }
                self.cacheContinuation = nil
                pending.resume(throwing: SpotifyDisplayError.bleTimeout)
            }
            p.writeValue(packet, for: c, type: .withResponse)
        }
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

    private func appendLog(_ entry: TransferLogEntry) {
        transferLog.append(entry)
        if transferLog.count > maxLogEntries {
            transferLog.removeFirst(transferLog.count - maxLogEntries)
        }
    }

    private func setLivePhase(_ text: String?) {
        currentLivePhase = text
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
        beginTransferBackgroundTaskIfNeeded()
        defer { endTransferBackgroundTaskIfNeeded() }
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

        let cacheCheckStart = CFAbsoluteTimeGetCurrent()
        setLivePhase("cache check + downloading…")
        let cacheHit: Bool
        let cacheKeySource = String.cacheKeySource(albumId: albumId, imageURL: primaryURL)
        let cacheKey = cacheKeySource.md5Digest
        awaitingCacheRenderConfirm = true
        cacheRenderConfirmed = false
        do {
            cacheHit = try await checkCacheHit(cacheKey: cacheKey)
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
                    if let data = try? await previewDownload.value {
                        self.currentAlbumArt = data
                    }
                }
                statusMessage = "Loaded from SD cache"
                let totalMs = ms(since: totalStart)
                setLivePhase("cache hit \(secondsLabel(fromMs: totalMs))")
                lastTransferResult = "Cache hit  \(secondsLabel(fromMs: totalMs))"
                boardAckStatus = "Board ACK: cache hit"
                lastConfirmedTrackId = trackId
                appendLog(TransferLogEntry(
                    cacheHit: true, transitionName: lastTransitionName, cacheCheckMs: cacheCheckMs,
                    downloadMs: nil, convertMs: nil, uploadMs: 0,
                    totalMs: totalMs, outcome: "cache hit"
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

        currentAlbumArt = data

        statusMessage = "Processing image…"
        setLivePhase("dithering…")
        let convertStart = CFAbsoluteTimeGetCurrent()
        let capturedData = data
        let rgb565 = try await Task.detached(priority: .userInitiated) {
            try ImageProcessor.convertToRGB565(imageData: capturedData)
        }.value
        let convertMs = ms(since: convertStart)
        setLivePhase("dither \(secondsLabel(fromMs: convertMs))")
        try ensureTransferEpoch(epochAtStart)

        guard rgb565.count == imagePayloadBytes else {
            throw SpotifyDisplayError.conversionFailed
        }

        let uploadStart = CFAbsoluteTimeGetCurrent()
        setLivePhase("sending BLE…")
        try await sendRGB565(rgb565, epochAtStart: epochAtStart)
        let uploadMs = ms(since: uploadStart)
        setLivePhase("sent \(secondsLabel(fromMs: uploadMs))")

        let totalMs = ms(since: totalStart)
        setLivePhase("done \(secondsLabel(fromMs: totalMs))")
        lastTransferResult = "Sent new  \(secondsLabel(fromMs: totalMs)) (dl \(secondsLabel(fromMs: downloadMs)))"
        boardAckStatus = "Board ACK: image sent"
        lastConfirmedTrackId = trackId
        appendLog(TransferLogEntry(
            cacheHit: false, transitionName: nil, cacheCheckMs: cacheCheckMs,
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

    func sendRGB565(_ rgb565: Data, epochAtStart: UInt64) async throws {
        try ensureTransferEpoch(epochAtStart)
        try ensureGattReady()
        guard let p = peripheral, let img = imageChar else { throw SpotifyDisplayError.notConnected }

        awaitingImageComplete = true
        defer { awaitingImageComplete = false }

        transferContinuation?.resume(throwing: CancellationError())
        transferContinuation = nil

        try ensureTransferEpoch(epochAtStart)

        var header = Data()
        header.append(0xFF) // Always random transition on firmware
        withUnsafeBytes(of: UInt32(imagePayloadBytes).littleEndian) { header.append(contentsOf: $0) }
        p.writeValue(header, for: img, type: .withResponse)

        try ensureTransferEpoch(epochAtStart)

        isTransferring = true
        transferProgress = 0

        let total = rgb565.count
        var offset = 0
        let useWithoutResponse = img.properties.contains(.writeWithoutResponse)
        let mtuWR = p.maximumWriteValueLength(for: .withoutResponse)
        let writeChunkSize = useWithoutResponse
            ? min(chunkSize, mtuWR > 0 ? mtuWR : chunkSize)
            : chunkSize

        while offset < total {
            try ensureTransferEpoch(epochAtStart)
            if useWithoutResponse {
                await awaitWriteWindow(peripheral: p)
            }
            try ensureTransferEpoch(epochAtStart)
            let end = min(offset + writeChunkSize, total)
            let chunk = rgb565.subdata(in: offset..<end)
            let wtype: CBCharacteristicWriteType = useWithoutResponse ? .withoutResponse : .withResponse
            p.writeValue(chunk, for: img, type: wtype)
            offset = end
            transferProgress = Double(offset) / Double(total)
            if !useWithoutResponse {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }

        try ensureTransferEpoch(epochAtStart)

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
            self.imageSuccessTimeoutTask = Task { @MainActor in
                defer { self.imageSuccessTimeoutTask = nil }
                do {
                    // Firmware ACK after progressive draw + SD save; typically <2s.
                    try await Task.sleep(nanoseconds: 8_000_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
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

        isTransferring = false
        transferProgress = 0
        statusMessage = "Sent to display"
        setLivePhase("idle")

        Task { @MainActor in
            try? await self.refreshSDCacheCount()
        }
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
        sawReady = false
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
        if isTransferring {
            isTransferring = false
            transferProgress = 0
        }
    }

    private func awaitWriteWindow(peripheral: CBPeripheral) async {
        while !peripheral.canSendWriteWithoutResponse {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                self.writeDrainContinuation = c
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
        if text == "READY" { signalReady() }

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
            }
        }
    }

    private func onCharacteristicsReady() async {
        guard let p = peripheral else { return }
        for ch in [statusChar, cacheChar, imageChar, msgChar].compactMap({ $0 }) {
            p.setNotifyValue(true, for: ch)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        do {
            try await waitForReady()
            if !readyEpochCommittedForConnection {
                readyEpoch &+= 1
                readyEpochCommittedForConnection = true
            }
            statusMessage = "Ready"
            // Re-apply persisted brightness value on every reconnect.
            setBrightness(brightness)
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
        Task { @MainActor in
            guard peripheral.name == "Spotify Display" else { return }
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
                    [self.statusUUID, self.cacheUUID, self.imageUUID, self.messageUUID, self.brightnessUUID],
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
                default: break
                }
            }
            if self.statusChar != nil, self.cacheChar != nil, self.imageChar != nil, self.msgChar != nil, self.brightnessChar != nil {
                Task { await self.onCharacteristicsReady() }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            guard let data = characteristic.value, error == nil else { return }

            switch characteristic.uuid {
            case self.statusUUID:
                if data.count == 1, data[0] == 0x01 { self.signalReady() }

            case self.cacheUUID:
                if data.count == 1, let c = self.cacheContinuation {
                    self.cacheContinuation = nil
                    c.resume(returning: data[0] == 0x01)
                }

            case self.imageUUID:
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

