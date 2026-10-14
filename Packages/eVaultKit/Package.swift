// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "eVaultKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "VaultCore", targets: ["VaultCore"]),
        .library(name: "EnvKit", targets: ["EnvKit"]),
        .library(name: "VaultSync", targets: ["VaultSync"]),
        .library(name: "ToolKit", targets: ["ToolKit"]),
        .executable(name: "evault", targets: ["evault"]),
    ],
    targets: [
        .target(name: "VaultCore"),
        .target(name: "EnvKit"),
        .target(name: "VaultSync", dependencies: ["VaultCore"]),
        .target(name: "ToolKit", dependencies: ["VaultCore", "EnvKit"]),
        .executableTarget(name: "evault", dependencies: ["VaultCore", "EnvKit"]),
        .testTarget(name: "VaultCoreTests", dependencies: ["VaultCore"]),
        .testTarget(name: "EnvKitTests", dependencies: ["EnvKit"]),
        .testTarget(name: "VaultSyncTests", dependencies: ["VaultSync", "VaultCore"]),
    ],
    swiftLanguageModes: [.v6]
)
