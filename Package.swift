// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "upmixd",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "upmixd", targets: ["upmixd"]),
        .executable(name: "upmix-panel", targets: ["UpmixPanel"]),
    ],
    targets: [
        .target(name: "UpmixCore"),
        .executableTarget(
            name: "upmixd",
            dependencies: ["UpmixCore"]
        ),
        .executableTarget(
            name: "UpmixPanel",
            dependencies: ["UpmixCore"]
        ),
        .testTarget(
            name: "UpmixCoreTests",
            dependencies: ["UpmixCore"]
        ),
    ]
)
