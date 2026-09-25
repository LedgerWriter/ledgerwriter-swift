// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ledgerwriter-swift",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "LedgerWriterAPI", targets: ["LedgerWriterAPI"]),
        .executable(name: "lw", targets: ["lw"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.7.0"),
        .package(url: "https://github.com/apple/swift-openapi-urlsession", from: "1.0.2"),
        .package(url: "https://github.com/apple/swift-http-types", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        // Client generated at build time from Sources/LedgerWriterAPI/openapi.yaml -- a vendored,
        // byte-identical copy of ledger-writer's apps/api-external/openapi.yaml (see SPEC_SOURCE
        // and ADR-14). Hand-written code in this target is ergonomics only.
        .target(
            name: "LedgerWriterAPI",
            dependencies: [
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIURLSession", package: "swift-openapi-urlsession"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
            plugins: [.plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")]
        ),
        .executableTarget(
            name: "lw",
            dependencies: [
                "LedgerWriterAPI",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "LedgerWriterAPITests",
            dependencies: [
                "LedgerWriterAPI",
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ]
        ),
    ]
)
