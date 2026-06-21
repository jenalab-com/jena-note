// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "JenaNote",
    platforms: [.macOS(.v11)],
    targets: [
        .target(name: "JenaNoteKit", path: "Sources/JenaNoteKit"),
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
