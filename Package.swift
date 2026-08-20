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
        .target(name: "UpmixDevices", dependencies: ["UpmixCore"]),
        .executableTarget(
            name: "upmixd",
            dependencies: ["UpmixCore", "UpmixDevices"]
        ),
        .executableTarget(
            name: "UpmixPanel",
            dependencies: ["UpmixCore", "UpmixDevices"]
        ),
        .testTarget(
            name: "UpmixCoreTests",
            dependencies: ["UpmixCore"]
        ),
        .testTarget(
            name: "UpmixPanelTests",
            dependencies: ["UpmixPanel", "UpmixCore", "UpmixDevices"]
        ),
    ]
)
