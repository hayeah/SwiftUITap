// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TodoList",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(name: "SwiftAgentSDK", path: "../../"),
    ],
    targets: [
        .executableTarget(
            name: "TodoList",
            dependencies: [.product(name: "SwiftAgentSDK", package: "SwiftAgentSDK")],
            path: "TodoList",
            exclude: ["Info.plist"]
        ),
    ]
)
