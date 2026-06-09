// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "apple-tasks",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0")
    ],
    targets: [
        .executableTarget(
            name: "apple-tasks",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/AppleTasks",
            exclude: ["Info.plist"],
            linkerSettings: [
                // Embed Info.plist so the bare executable can request Reminders access (TCC).
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/AppleTasks/Info.plist",
                ])
            ]
        )
    ]
)
