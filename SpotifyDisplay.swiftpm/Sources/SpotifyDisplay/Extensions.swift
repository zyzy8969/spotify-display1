import Foundation
import CryptoKit

extension String {
    /// Raw 16-byte MD5 digest of UTF-8 (matches Python `hashlib.md5(url.encode()).digest()`).
    var md5Digest: Data {
        let data = Data(self.utf8)
        let hash = Insecure.MD5.hash(data: data)
        return Data(hash)
    }
}
