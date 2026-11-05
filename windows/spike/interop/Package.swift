// swift-tools-version:5.7
import Foundation
import PackageDescription

// Spike only. Compiles unmodified macOS sources copied in by ../spike.ps1 (see README).
// The module keeps the name JenaNoteKit so the macOS tests compile without edits.
let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let kiwiLibDir = packageDir + "/../.out/kiwi/Release"

let package = Package(
    name: "JenaNoteSpike",
    products: [.library(name: "JenaNoteKit", type: .dynamic, targets: ["JenaNoteKit"])],
    targets: [
        .systemLibrary(name: "Kiwi", path: "Modules/Kiwi"),
        .target(
            name: "JenaNoteKit",
            dependencies: ["Kiwi"],
            path: "Sources/JenaNoteKit",
            resources: [.copy("Resources/KiwiModel")],
            linkerSettings: [.unsafeFlags(["-L", kiwiLibDir])]
        ),
        .testTarget(
            name: "JenaNoteKitTests",
            dependencies: ["JenaNoteKit"],
            path: "Tests/JenaNoteKitTests",
            linkerSettings: [.unsafeFlags(["-L", kiwiLibDir])]
        ),
    ]
)
