// swift-tools-version:5.7
import Foundation
import PackageDescription

// JenaNoteCore (shared/) builds on macOS and Windows. The AppKit app exists only on macOS.
// One package rather than two: SwiftPM targets cannot point outside their package root,
// and Kiwi lives in Vendor/.
#if os(Windows)
let kiwiLibraryDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path + "/windows/.out/kiwi/Release"
let kiwiTarget: Target = .systemLibrary(name: "Kiwi", path: "windows/kiwi")
let coreLinkerSettings: [LinkerSetting] = [.unsafeFlags(["-L", kiwiLibraryDirectory])]
let appTargets: [Target] = []
// The Windows app loads this as a DLL.
let platformProducts: [Product] = [.library(name: "JenaNoteCore", type: .dynamic, targets: ["JenaNoteCore"])]
#else
let kiwiTarget: Target = .binaryTarget(name: "Kiwi", path: "Vendor/Kiwi/Kiwi.xcframework")
let coreLinkerSettings: [LinkerSetting] = [.linkedLibrary("c++")]
let appTargets: [Target] = [
    .target(name: "JenaNoteKit", dependencies: ["JenaNoteCore"], path: "Sources/JenaNoteKit",
            resources: [.copy("Resources/ThirdParty")]),
    .executableTarget(
        name: "JenaNote",
        dependencies: ["JenaNoteKit"],
        path: "Sources/JenaNote"
    ),
    .testTarget(
        name: "JenaNoteKitTests",
        dependencies: ["JenaNoteKit", "JenaNoteCoreTestSupport"],
        path: "Tests/JenaNoteKitTests"
    ),
]
let platformProducts: [Product] = []
#endif

let package = Package(
    name: "JenaNote",
    platforms: [.macOS(.v13)],
    products: platformProducts,
    targets: [
        kiwiTarget,
        .target(name: "JenaNoteCore", dependencies: ["Kiwi"], path: "shared/JenaNoteCore",
                resources: [.copy("Resources/KiwiModel")],
                linkerSettings: coreLinkerSettings),
        .target(name: "JenaNoteCoreTestSupport", path: "shared/TestSupport"),
        .testTarget(
            name: "JenaNoteCoreTests",
            dependencies: ["JenaNoteCore", "JenaNoteCoreTestSupport"],
            path: "shared/Tests/JenaNoteCoreTests",
            linkerSettings: coreLinkerSettings
        ),
    ] + appTargets
)
