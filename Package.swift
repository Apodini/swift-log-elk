// swift-tools-version:5.5

import PackageDescription


let package = Package(
    name: "swift-log-elk",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13)
    ],
    products: [
        .library(name: "LoggingELK", targets: ["LoggingELK"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", .upToNextMajor(from: "1.4.0")),
        .package(url: "https://github.com/swift-server/async-http-client.git", .upToNextMajor(from: "1.5.0"))
    ],
    targets: [
        .target(
            name: "LoggingELK",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "AsyncHTTPClient", package: "async-http-client")
            ]
        ),
        .testTarget(
            name: "LoggingELKTests",
            dependencies: [
                .target(name: "LoggingELK")
            ]
        )
    ]
)
