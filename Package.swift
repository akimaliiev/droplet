// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Droplet",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Droplet",
            path: "Sources/Droplet",
            swiftSettings: [.unsafeFlags(["-swift-version", "5"])]
        )
    ]
)
