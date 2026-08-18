// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "apple-tasks-server",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "apple-tasks-server", targets: ["apple-tasks-server"]),
        .library(name: "AppleTasksServerCore", targets: ["AppleTasksServerCore"])
    ],
    targets: [
        .target(
            name: "AppleTasksServerCore",
            path: "Sources/AppleTasksServerCore"
        ),
        .executableTarget(
            name: "apple-tasks-server",
            dependencies: ["AppleTasksServerCore"],
            path: "Sources/AppleTasksServer"
        ),
        .testTarget(
            name: "AppleTasksServerTests",
            dependencies: ["AppleTasksServerCore"],
            path: "Tests/AppleTasksServerTests"
        )
    ]
)
