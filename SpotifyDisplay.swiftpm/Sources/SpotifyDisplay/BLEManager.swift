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

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var statusChar: CBCharacteristic?
    private var cacheChar: CBCharacteristic?
    private var imageChar: CBCharacteristic?
    private var msgChar: CBCharacteristic?

    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var cacheContinuation: CheckedContinuation<Bool, Error>?
    private var transferContinuation: CheckedContinuation<Void, Error>?
    private var statsContinuation: CheckedContinuation<Int, Error>?
    /// CoreBluetooth write queue (without-response) drain signal
    private var writeDrainContinuation: CheckedContinuation<Void, Never>?

    private var sawReady = false
    private var awaitingImageComplete = false

    /// Set in `centralManager(_:willRestoreState:)` and consumed when the central becomes `.poweredOn`.
    private var pendingRestoredPeripheral: CBPeripheral?

    /// Lets an in-flight album transfer finish after the app moves to background (best-effort, seconds).
    private var transferBackgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    /// Cancels the 32s `SUCCESS` wait when the firmware ACKs early (saves idle sleep + CPU).
    private var imageSuccessTimeoutTask: Task<Void, Never>?

    /// Incremented on `cancelOngoingTransfer()` and `failPending` so in-flight `processTrack` / `sendRGB565` abort cooperatively.
    private var transferEpoch: UInt64 = 0
    private var activeDownloadTask: Task<(Data, URLResponse), Error>?

    private let serviceUUID = CBUUID(string: "0000FFE0-0000-1000-8000-00805F9B34FB")
    private let statusUUID = CBUUID(string: "0000FFE1-0000-1000-8000-00805F9B34FB")
    private let cacheUUID = CBUUID(string: "0000FFE2-0000-1000-8000-00805F9B34FB")
    private let imageUUID = CBUUID(string: "0000FFE3-0000-1000-8000-00805F9B34FB")
    private let messageUUID = CBUUID(string: "0000FFE4-0000-1000-8000-00805F9B34FB")

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
        statusMessage = "Discovering services…"
        peripheral.discoverServices([serviceUUID])
    }

    func startScanning() {
        guard central.state == .poweredOn else { return }
        statusMessage = "Scanning for Spotify Display…"
        central.scanForPeripherals(withServices: [serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    /// Cache-only check (same 20-byte packet as Python).
    func checkCacheHit(imageURL: String) async throws -> Bool {
        try ensureGattReady()
        guard let p = peripheral, let c = cacheChar else { throw SpotifyDisplayError.notConnected }

        cacheContinuation?.resume(throwing: CancellationError())
        cacheContinuation = nil

        var packet = Data()
        withUnsafeBytes(of: cacheMagic.littleEndian) { packet.append(contentsOf: $0) }
        packet.append(imageURL.md5Digest)

        return try await withCheckedThrowingContinuation { cont in
            self.cacheContinuation = cont
            p.writeValue(packet, for: c, type: .withResponse)
        }
    }

    /// Aborts in-flight album download and BLE chunk loop. Next `processTrack` uses a fresh epoch; send a new image header on the next transfer so the ESP32 can resync if the previous send was partial.
    func cancelOngoingTransfer() {
        transferEpoch += 1
        cancelImageSuccessTimeoutTask()
        activeDownloadTask?.cancel()
        activeDownloadTask = nil
        transferContinuation?.resume(throwing: CancellationError())
        transferContinuation = nil
        if isTransferring {
            isTransferring = false
            transferProgress = 0
        }
    }

    private func ensureTransferEpoch(_ epochAtStart: UInt64) throws {
        if epochAtStart != transferEpoch {
            throw CancellationError()
        }
    }

    /// Parallel download + cache check (like desktop script), then send on miss.
    func processTrack(imageURL: String, trackId _: String) async throws {
        beginTransferBackgroundTaskIfNeeded()
        defer { endTransferBackgroundTaskIfNeeded() }

        let epochAtStart = transferEpoch
        try ensureTransferEpoch(epochAtStart)

        guard let u = URL(string: imageURL) else { throw SpotifyDisplayError.conversionFailed }

        let download = Task { try await URLSession.shared.data(from: u) }
        activeDownloadTask = download

        let cacheHit: Bool
        do {
            cacheHit = try await checkCacheHit(imageURL: imageURL)
        } catch {
            download.cancel()
            activeDownloadTask = nil
            throw error
        }

        try ensureTransferEpoch(epochAtStart)

        if cacheHit {
            download.cancel()
            activeDownloadTask = nil
            statusMessage = "Loaded from SD cache"
            return
        }

        let (data, _): (Data, URLResponse)
        do {
            (data, _) = try await download.value
        } catch {
            activeDownloadTask = nil
            throw error
        }
        activeDownloadTask = nil

        try ensureTransferEpoch(epochAtStart)

        currentAlbumArt = data

        statusMessage = "Processing image…"
        let rgb565 = try ImageProcessor.convertToRGB565(imageData: data)
        try ensureTransferEpoch(epochAtStart)

        guard rgb565.count == imagePayloadBytes else {
            throw SpotifyDisplayError.conversionFailed
        }

        try await sendRGB565(rgb565, epochAtStart: epochAtStart)
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

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.transferContinuation = cont
            self.cancelImageSuccessTimeoutTask()
            self.imageSuccessTimeoutTask = Task { @MainActor in
                defer { self.imageSuccessTimeoutTask = nil }
                do {
                    // Firmware ACK after dither + redraw + SD save (main.cpp); allow slow SD paths.
                    try await Task.sleep(nanoseconds: 32_000_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                if let c = self.transferContinuation {
                    self.transferContinuation = nil
                    c.resume(throwing: SpotifyDisplayError.bleTimeout)
                }
            }
        }

        cancelImageSuccessTimeoutTask()

        try ensureTransferEpoch(epochAtStart)

        isTransferring = false
        transferProgress = 0
        statusMessage = "Sent to display"

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

        let count = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int, Error>) in
            self.statsContinuation = cont
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if let c = self.statsContinuation {
                    self.statsContinuation = nil
                    c.resume(throwing: SpotifyDisplayError.bleTimeout)
                }
            }
            p.writeValue(packet, for: c, type: .withResponse)
        }
        sdCacheEntryCount = count
    }

    private func ensureGattReady() throws {
        guard isConnected, statusChar != nil, cacheChar != nil, imageChar != nil, msgChar != nil else {
            throw SpotifyDisplayError.notConnected
        }
    }

    private func resetGattState() {
        statusChar = nil
        cacheChar = nil
        imageChar = nil
        msgChar = nil
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
        statsContinuation?.resume(throwing: error)
        statsContinuation = nil
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
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.readyContinuation = cont
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                if let c = self.readyContinuation {
                    self.readyContinuation = nil
                    c.resume(throwing: SpotifyDisplayError.bleTimeout)
                }
            }
        }
    }

    private func handleMessage(_ text: String) {
        if text == "READY" { signalReady() }

        if text == "SUCCESS", awaitingImageComplete {
            if let c = transferContinuation {
                transferContinuation = nil
                cancelImageSuccessTimeoutTask()
                c.resume()
            }
        }

        if text.hasPrefix("CACHE_COUNT:") {
            let rest = text.dropFirst("CACHE_COUNT:".count)
            if let n = Int(rest) {
                sdCacheEntryCount = n
                if let c = statsContinuation {
                    statsContinuation = nil
                    c.resume(returning: n)
                }
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
            statusMessage = "Ready"
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
            self.sdCacheEntryCount = nil
            self.sdCacheCountLoading = false
            self.resetGattState()
            self.statusMessage = "Disconnected — retrying…"
            self.failPending(error: SpotifyDisplayError.notConnected)
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
                    [self.statusUUID, self.cacheUUID, self.imageUUID, self.messageUUID],
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
                default: break
                }
            }
            if self.statusChar != nil, self.cacheChar != nil, self.imageChar != nil, self.msgChar != nil {
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
                if data.count == 1, data[0] == 0x01, self.awaitingImageComplete, let c = self.transferContinuation {
                    self.transferContinuation = nil
                    self.cancelImageSuccessTimeoutTask()
                    c.resume()
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
