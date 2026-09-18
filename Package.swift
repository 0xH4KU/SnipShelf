// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SnipShelf",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "SnipShelf", targets: ["SnipShelf"]),
               .executable(name: "PaletteLab", targets: ["PaletteLab"])],
    targets: [
        .target(name: "PaletteKit"),
        .executableTarget(name: "SnipShelf", dependencies: ["PaletteKit"]),
        .testTarget(name: "SnipShelfTests", dependencies: ["SnipShelf", "PaletteKit"]),
        .executableTarget(name: "PaletteLab", dependencies: ["PaletteKit"]),
        .testTarget(name: "PaletteLabTests", dependencies: ["PaletteLab", "PaletteKit"])
    ],
    swiftLanguageModes: [.v5]
)
