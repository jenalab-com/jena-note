// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "JenaNote",
    platforms: [.macOS(.v11)],
    targets: [
        .binaryTarget(name: "Kiwi", path: "Vendor/Kiwi/Kiwi.xcframework"),
        .target(name: "JenaNoteKit", dependencies: ["Kiwi"], path: "Sources/JenaNoteKit",
                resources: [.copy("Resources/KiwiModel"), .copy("Resources/ThirdParty")],
                linkerSettings: [.linkedLibrary("c++")]),
        .executableTarget(
            name: "JenaNote",
            dependencies: ["JenaNoteKit"],
            path: "Sources/JenaNote"
        ),
        .testTarget(
            name: "JenaNoteKitTests",
            dependencies: ["JenaNoteKit"],
            path: "Tests/JenaNoteKitTests"
        ),
    ]
)
