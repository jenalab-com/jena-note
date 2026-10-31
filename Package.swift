// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "JenaNote",
    platforms: [.macOS(.v11)],
    targets: [
        .binaryTarget(name: "Kiwi", url: "https://github.com/bab2min/Kiwi/releases/download/v0.24.1/Kiwi.xcframework.zip",
                      checksum: "450236d499ed150d39deded4ec1676b607dcd8bfe111806cb9a8b450870f1384"),
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
