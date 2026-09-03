// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HypoHarness",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(path: "../../shared/HypoCore")
    ],
    targets: [
        .executableTarget(
            name: "HypoHarness",
            dependencies: [.product(name: "HypoCore", package: "HypoCore")]
        )
    ]
)
