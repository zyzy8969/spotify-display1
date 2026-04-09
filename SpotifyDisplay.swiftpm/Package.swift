// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SpotifyDisplay",
    platforms: [.iOS(.v16)],
    products: [
        .executable(name: "SpotifyDisplay", targets: ["SpotifyDisplay"])
    ],
    targets: [
        .executableTarget(
            name: "SpotifyDisplay",
            path: "Sources/SpotifyDisplay",
            resources: [.process("Resources")]
        )
    ]
)
