// swift-tools-version: 5.9
// Rockit Language — Bootstrap Compiler (Stage 0)
// Dark Matter Tech

import PackageDescription

#if os(Linux)
let platformTargets: [Target] = [
    .systemLibrary(
        name: "COpenSSL",
        path: "Sources/COpenSSL",
        pkgConfig: "openssl",
        providers: [.apt(["libssl-dev"])]
    ),
]
let openSSLDep: [Target.Dependency] = [
    .target(name: "COpenSSL", condition: .when(platforms: [.linux])),
]
#else
let platformTargets: [Target] = []
let openSSLDep: [Target.Dependency] = []
#endif

let package = Package(
    name: "rockit-lang",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "rockit", targets: ["RockitCLI"]),
        .library(name: "RockitKit", targets: ["RockitKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: platformTargets + [
        .target(
            name: "RockitKit",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
            ] + openSSLDep,
            path: "Sources/RockitKit"
        ),
        .target(
            name: "RockitLSP",
            dependencies: ["RockitKit"],
            path: "Sources/RockitLSP"
        ),
        .executableTarget(
            name: "RockitCLI",
            dependencies: ["RockitKit", "RockitLSP"],
            path: "Sources/RockitCLI"
        ),
        .testTarget(
            name: "RockitKitTests",
            dependencies: ["RockitKit"],
            path: "Tests/RockitKitTests"
        ),
    ]
)