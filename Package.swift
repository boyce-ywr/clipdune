// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClipDune",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClipDune", targets: ["ClipDuneApp"]),
        .executable(name: "ClipDuneQAHost", targets: ["ClipDuneQAHost"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "ClipDuneCore", dependencies: ["CSQLite"]),
        .target(name: "ClipDuneMac", dependencies: ["ClipDuneCore"]),
        .executableTarget(name: "ClipDuneApp", dependencies: ["ClipDuneCore", "ClipDuneMac"]),
        .executableTarget(name: "ClipDuneQAHost"),
        .executableTarget(name: "ClipDuneChecks", dependencies: ["ClipDuneCore", "ClipDuneMac"], path: "Tests/ClipDuneTests")
    ],
    swiftLanguageModes: [.v5]
)
