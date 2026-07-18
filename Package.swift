// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KVNetworkit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
    ],
    products: [
        .library(name: "KVNetworkit", targets: ["KVNetworkit"])
    ],
    targets: [
        .target(
            name: "KVNetworkit"
        ),
        .testTarget(
            name: "KVNetworkitTests",
            dependencies: ["KVNetworkit"]
        )
    ]
)
