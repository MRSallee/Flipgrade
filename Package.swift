// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Flipgrade",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Flipgrade", targets: ["Flipgrade"])
    ],
    targets: [
        .executableTarget(
            name: "Flipgrade",
            path: "Sources/Flipgrade"
        )
    ]
)
