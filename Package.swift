// swift-tools-version: 5.9

import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "SwiftUITap",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "SwiftUITap",
            targets: ["SwiftUITap"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "509.0.0"),
    ],
    targets: [
        .macro(
            name: "SwiftUITapMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ],
            path: "Sources/SwiftUITapMacros"
        ),
        .target(
            name: "TapDispatchObjC",
            path: "Sources/TapDispatchObjC",
            publicHeadersPath: "include"
        ),
        .target(
            name: "SwiftUITap",
            dependencies: ["SwiftUITapMacros", "TapDispatchObjC"],
            path: "Sources/SwiftUITap"
        ),
        .testTarget(
            name: "SwiftUITapTests",
            dependencies: [
                "SwiftUITapMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ]
        ),
    ]
)
