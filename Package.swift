// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ASCBridge",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ASCBridge", targets: ["ASCBridge"]),
        .library(name: "BridgeCore", targets: ["BridgeCore"]),
        .library(name: "BridgeMCP", targets: ["BridgeMCP"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", exact: "2.20.0"),
    ],
    targets: [
        .target(name: "BridgeCore", resources: [.process("Resources")]),
        .target(name: "BridgeMCP", dependencies: [
            "BridgeCore",
            .product(name: "MCP", package: "swift-sdk"),
            .product(name: "Hummingbird", package: "hummingbird"),
        ]),
        .executableTarget(name: "ASCBridge", dependencies: ["BridgeCore", "BridgeMCP"], resources: [.process("Resources")]),
        .testTarget(name: "ASCBridgeTests", dependencies: ["ASCBridge", "BridgeCore"]),
        .testTarget(name: "BridgeCoreTests", dependencies: ["BridgeCore"]),
        .testTarget(name: "BridgeMCPTests", dependencies: [
            "BridgeCore", "BridgeMCP", .product(name: "MCP", package: "swift-sdk"),
        ]),
    ]
)
