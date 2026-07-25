// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Wysi",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Wysi", path: "Sources/Wysi"),
        .testTarget(name: "WysiTests", dependencies: ["Wysi"], path: "Tests/WysiTests")
    ]
)
