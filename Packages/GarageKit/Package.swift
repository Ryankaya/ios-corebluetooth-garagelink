// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GarageKit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "GarageProtocol", targets: ["GarageProtocol"]),
    ],
    targets: [
        .target(name: "GarageProtocol"),
        .testTarget(name: "GarageProtocolTests", dependencies: ["GarageProtocol"]),
    ]
)
