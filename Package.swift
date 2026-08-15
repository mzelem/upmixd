// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "upmixd",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "UpmixCore"),
        .executableTarget(
            name: "upmixd",
            dependencies: ["UpmixCore"]
        ),
        .testTarget(
            name: "UpmixCoreTests",
            dependencies: ["UpmixCore"]
        ),
    ]
)
