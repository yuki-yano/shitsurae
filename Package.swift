// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "shitsurae",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "ShitsuraeCore", targets: ["ShitsuraeCore"]),
        .executable(name: "shitsurae-cli", targets: ["ShitsuraeCLI"]),
        .executable(name: "Shitsurae", targets: ["Shitsurae"]),
        .executable(name: "ShitsuraeAgent", targets: ["ShitsuraeAgent"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.3")
    ],
    targets: [
        .target(
            name: "ShitsuraeCore",
            dependencies: [
                .product(name: "Yams", package: "Yams")
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "ShitsuraeCLI",
            dependencies: [
                "ShitsuraeCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/ShitsuraeCLI"
        ),
        .executableTarget(
            name: "Shitsurae",
            dependencies: ["ShitsuraeCore"],
            path: "Sources/ShitsuraeMain"
        ),
        .executableTarget(
            name: "ShitsuraeAgent",
            dependencies: ["ShitsuraeCore"]
        ),
        .testTarget(
            name: "ShitsuraeCoreTests",
            dependencies: ["ShitsuraeCore"]
        )
    ]
)
