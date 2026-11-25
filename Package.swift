// swift-tools-version:6.4
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "mcp-swift-sdk",
    platforms: [
        .macOS("13.0"),
        .macCatalyst("16.0"),
        .iOS("16.0"),
        .watchOS("9.0"),
        .tvOS("16.0"),
        .visionOS("1.0"),
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "MCP",
            targets: ["MCP"]),
        .library(
            name: "MCPSkills",
            targets: ["MCPSkills"]),
        .executable(
            name: "mcp-everything-server",
            targets: ["MCPConformanceServer"]),
        .executable(
            name: "mcp-everything-client",
            targets: ["MCPConformanceClient"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", exact: "1.4.6"),
        .package(url: "https://github.com/apple/swift-system.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/mattt/eventsource.git", from: "1.1.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"6.0.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.0.0"),
    ],
    targets: [
        .target(
            name: "MCP",
            dependencies: [
                .product(name: "SystemPackage", package: "swift-system"),
                .product(name: "Logging", package: "swift-log"),
                .product(
                    name: "EventSource", package: "eventsource",
                    condition: .when(platforms: [.macOS, .iOS, .tvOS, .visionOS, .watchOS, .macCatalyst])),
            ],
            exclude: [
                "DESIGN.md",
                "Base/DESIGN.md",
                "Base/Authorization/DESIGN.md",
                "Base/Transports/DESIGN.md",
                "Client/DESIGN.md",
                "Server/DESIGN.md",
            ],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .target(
            name: "MCPSkills",
            dependencies: [
                "MCP",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Yams", package: "Yams"),
                .product(name: "SystemPackage", package: "swift-system"),
            ],
            exclude: ["DESIGN.md"],
            swiftSettings: [
                .enableUpcomingFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "MCPSkillsTests",
            dependencies: [
                "MCP",
                "MCPSkills",
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .testTarget(
            name: "MCPTests",
            dependencies: [
                "MCP",
                .product(name: "SystemPackage", package: "swift-system"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOConcurrencyHelpers", package: "swift-nio"),
                .product(
                    name: "EventSource", package: "eventsource",
                    condition: .when(platforms: [.macOS, .iOS, .tvOS, .visionOS, .watchOS, .macCatalyst])),
            ]
        ),
        .executableTarget(
            name: "MCPConformanceServer",
            dependencies: [
                "MCP",
                "MCPSkills",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "Sources/MCPConformance/Server",
            exclude: ["DESIGN.md"]
        ),
        .executableTarget(
            name: "MCPConformanceClient",
            dependencies: [
                "MCP",
                "MCPSkills",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/MCPConformance/Client",
            exclude: ["DESIGN.md"]
        )
    ]
)
