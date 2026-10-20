// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EnVaultKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VaultCore", targets: ["VaultCore"]),
        .library(name: "EnvKit", targets: ["EnvKit"]),
        .library(name: "VaultSync", targets: ["VaultSync"]),
        .library(name: "ToolKit", targets: ["ToolKit"]),
        .executable(name: "envault", targets: ["envault"]),
        .library(name: "LicenseKit", targets: ["LicenseKit"]),
        .executable(name: "envault-license", targets: ["envault-license"]),
    ],
    targets: [
        .target(name: "VaultCore"),
        .target(name: "EnvKit"),
        .target(name: "VaultSync", dependencies: ["VaultCore"]),
        .target(name: "ToolKit", dependencies: ["VaultCore", "EnvKit"]),
        .executableTarget(name: "envault", dependencies: ["VaultCore", "EnvKit", "LicenseKit"]),
        .target(name: "LicenseKit"),
        .executableTarget(name: "envault-license", dependencies: ["LicenseKit"]),
        .testTarget(name: "LicenseKitTests", dependencies: ["LicenseKit"]),
        .testTarget(name: "VaultCoreTests", dependencies: ["VaultCore"]),
        .testTarget(name: "EnvKitTests", dependencies: ["EnvKit"]),
        .testTarget(name: "VaultSyncTests", dependencies: ["VaultSync", "VaultCore"]),
    ],
    swiftLanguageModes: [.v6]
)
