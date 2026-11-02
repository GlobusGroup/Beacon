// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Beacon",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "BeaconKit", targets: ["BeaconKit"]),
        .executable(name: "beacond", targets: ["beacond"]),
        .executable(name: "beacon", targets: ["beacon"]),
        .executable(name: "beacon-relay", targets: ["beacon-relay"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.99.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.9.2"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.9.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"6.0.0"),
    ],
    targets: [
        // Shared model/IPC layer. Lives inside the app's synchronized folder so the
        // Xcode app target compiles the exact same sources without a package reference.
        .target(
            name: "BeaconKit",
            path: "Beacon/Shared",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Tunnel wire format and the HTTP head handling shared by beacond and
        // beacon-relay. Foundation and SwiftNIO only, so it builds on Linux.
        .target(
            name: "BeaconTunnel",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/BeaconTunnel",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "beacond",
            dependencies: [
                "BeaconKit",
                "BeaconTunnel",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/beacond",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "beacon",
            dependencies: [
                "BeaconKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/beacon",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The public end of the tunnels. Runs on Linux, in Docker; see Relay/.
        .executableTarget(
            name: "beacon-relay",
            dependencies: [
                "BeaconTunnel",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Sources/beacon-relay",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
