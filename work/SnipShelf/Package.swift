// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SnipShelf",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "SnipShelf", targets: ["SnipShelf"])],
    targets: [
        .executableTarget(name: "SnipShelf"),
        .testTarget(name: "SnipShelfTests", dependencies: ["SnipShelf"])
    ],
    swiftLanguageModes: [.v5]
)
