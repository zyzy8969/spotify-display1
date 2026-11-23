import Foundation
import CryptoKit

extension String {
    /// Raw 16-byte MD5 digest of UTF-8 (matches Python `hashlib.md5(url.encode()).digest()`).
    var md5Digest: Data {
        let data = Data(self.utf8)
        let hash = Insecure.MD5.hash(data: data)
        return Data(hash)
    }

    /// Canonical cache identifier source sent to firmware (firmware controls filename/versioning).
    static func cacheKeySource(albumId: String?, imageURL: String) -> String {
        // Each dither mode is a different picture, so it gets its own cache entry on the board.
        ((albumId?.isEmpty == false) ? "album:\(albumId!)" : "url:\(imageURL)") + DitherMode.current.cacheKeySuffix
    }

    /// Cache identifier source for an uploaded photo: its bytes' hash, so the same photo always maps to
    /// the same entry on the keychain's card (and a re-show is a cache hit).
    static func photoCacheKeySource(jpeg: Data) -> String {
        let hex = Insecure.MD5.hash(data: jpeg).map { String(format: "%02x", $0) }.joined()
        return "photo:" + hex + DitherMode.current.cacheKeySuffix
    }
}

