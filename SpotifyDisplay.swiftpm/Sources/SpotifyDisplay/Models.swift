import Foundation

struct Track: Codable, Identifiable {
    let id: String
    let name: String
    let artists: [Artist]
    let album: Album?
}

struct Artist: Codable {
    let name: String
}

struct Album: Codable {
    let name: String
    let images: [AlbumImage]
}

struct AlbumImage: Codable {
    let url: String
    let height: Int?
    let width: Int?
}

enum SpotifyDisplayError: Error {
    case notConnected
    case conversionFailed
    case bleTimeout
    case authFailed
    case missingClientId
}
