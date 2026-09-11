// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Colok",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "colok", targets: ["colok"]),
        .executable(name: "ColokBar", targets: ["ColokBar"]),
        .library(name: "ColokCore", targets: ["ColokCore"]),
    ],
    targets: [
        .target(name: "ColokCore"),
        .executableTarget(name: "colok", dependencies: ["ColokCore"]),
        .executableTarget(name: "ColokBar", dependencies: ["ColokCore"]),
    ]
)
