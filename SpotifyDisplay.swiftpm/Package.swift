// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SpotifyDisplay",
    platforms: [.iOS(.v16)],
    products: [
        .executable(name: "SpotifyDisplay", targets: ["SpotifyDisplay"])
    ],
    targets: [
        // The board's transition code, shared with the ESP32 firmware (C API in include/).
        .target(
            name: "TransitionsCore",
            path: "Sources/TransitionsCore",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "SpotifyDisplay",
            dependencies: ["TransitionsCore"],
            path: "Sources/SpotifyDisplay",
            resources: [.process("Resources")]
        )
    ]
)
