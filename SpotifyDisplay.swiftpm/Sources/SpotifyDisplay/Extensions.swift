import Foundation
import CryptoKit

extension String {
    /// Raw 16-byte MD5 digest of UTF-8 (matches Python `hashlib.md5(url.encode()).digest()`).
    var md5Digest: Data {
        let data = Data(self.utf8)
        let hash = Insecure.MD5.hash(data: data)
        return Data(hash)
    }

    /// Firmware-owned cache semantics v1: app only sends canonical identifier hint.
    static let firmwareCacheKeyVersion = 1

    /// Canonical cache identifier source sent to firmware (firmware controls filename/versioning).
    static func cacheKeySource(albumId: String?, imageURL: String) -> String {
        (albumId?.isEmpty == false) ? "album:\(albumId!)" : "url:\(imageURL)"
    }

    /// BLE transport key: 16-byte digest of canonical source.
    static func cacheKeyDigest(albumId: String?, imageURL: String) -> Data {
        cacheKeySource(albumId: albumId, imageURL: imageURL).md5Digest
    }
}

// #region agent log
/// Session `de5a9b`. Writes NDJSON only to disk (Simulator host `Documents/.cursor/` + app `Library/Caches/`);
/// HTTP ingest to localhost is omitted — it spams the console with -1004 when Cursor’s ingest server is not running.
enum AgentDebugLog {
    private static let sessionId = "de5a9b"
    private static var didLogNativePath = false

    private static func appendNDJSONLine(_ body: Data, to path: String) {
        let url = URL(fileURLWithPath: path)
        let line = body + Data("\n".utf8)
        if !FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: path, contents: line)
        } else if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            h.seekToEndOfFile()
            h.write(line)
        }
    }

    static func ingest(hypothesisId: String, location: String, message: String, data: [String: Any] = [:]) {
        let payload: [String: Any] = [
            "sessionId": sessionId,
            "hypothesisId": hypothesisId,
            "location": location,
            "message": message,
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
            "data": data
        ]
        guard JSONSerialization.isValidJSONObject(payload),
              let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        // (1) Simulator: Mac host path matching Cursor workspace, when available.
        if let host = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"], !host.isEmpty {
            appendNDJSONLine(body, to: host + "/Documents/.cursor/debug-de5a9b.log")
        }
        // (2) Always: app Caches (Simulator + device) so logs exist even if host write fails.
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let cachePath = caches.appendingPathComponent("debug-de5a9b.log").path
            appendNDJSONLine(body, to: cachePath)
            if !didLogNativePath {
                didLogNativePath = true
                NSLog("AGENT_DEBUG_ndjson_path=%@", cachePath)
            }
        }
    }
}
// #endregion agent log
