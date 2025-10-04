// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Telegrambot",
    platforms: [
        .macOS(.v10_15)
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", from: "4.89.0"),
        .package(url: "https://github.com/vapor/fluent.git", from: "4.8.0"),
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.0.0")
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
                .product(name: "Vapor", package: "vapor")
            ],
            path: "Roundsvideobot/App"
        ),
        .target(
            name: "VideoService",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver")
            ],
            path: "Roundsvideobot/VideoService"
        ),
        .executableTarget(
            name: "VideoServiceRunner",
            dependencies: [
                .target(name: "VideoService"),
                .product(name: "Vapor", package: "vapor")
            ],
            path: "Roundsvideobot/VideoServiceRunner"
        ),
        .testTarget(
            name: "AppTests",
            dependencies: [
                .target(name: "App"),
                .product(name: "XCTVapor", package: "vapor")
            ]
        )
    ]
)