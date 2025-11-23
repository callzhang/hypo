// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TestHotkey",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "TestHotkey",
            targets: ["TestHotkey"]
        )
    ],
    targets: [
        .executableTarget(
            name: "TestHotkey",
            path: "."
        )
    ]
)


