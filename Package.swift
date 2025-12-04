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
        .package(url: "https://github.com/vapor/fluent-sqlite-driver.git", from: "4.0.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.0")
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
            path: "Roundsvideobot/VideoService",
            resources: [
                .process("Public")
            ]
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
        ),
        .executableTarget(
            name: "VeoNowBot",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver")
            ],
            path: "VeoNowBot/Sources/App"
        ),
        .executableTarget(
            name: "NowControllerBot",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver")
            ],
            path: "nowcontrollerbot/Sources/App"
        ),
        .executableTarget(
            name: "NowmttBot",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver")
            ],
            path: "nowmttbot/Sources/App"
        ),
        .executableTarget(
            name: "GSForTextBot",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver")
            ],
            path: "gsfortextbot/Sources/App"
        ),
        .executableTarget(
            name: "SoranowBot",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver")
            ],
            path: "soranowbot/Sources/App"
        ),
        .executableTarget(
            name: "BananaNowBot",
            dependencies: [
                .product(name: "Vapor", package: "vapor")
            ],
            path: "BananaNowBot/Sources/App"
        ),
        .executableTarget(
            name: "ContentFabrikaBot",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver")
            ],
            path: "contentfabrikabot/Sources/App"
        ),
        .executableTarget(
            name: "Neurfotobot",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "Fluent", package: "fluent"),
                .product(name: "FluentSQLiteDriver", package: "fluent-sqlite-driver"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ],
            path: "Neurfotobot/Sources/App"
        )
    ]
)