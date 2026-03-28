// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "TodoListiOS",
    platforms: [
        .iOS(.v17),
    ],
    dependencies: [
        .package(name: "SwiftAgentSDK", path: "../../"),
    ],
    targets: [
        .executableTarget(
            name: "TodoListiOS",
            dependencies: [.product(name: "SwiftAgentSDK", package: "SwiftAgentSDK")],
            path: "TodoListiOS"
        ),
    ]
)
