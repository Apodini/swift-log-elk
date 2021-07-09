// swift-tools-version:5.4

import PackageDescription


let package = Package(
    name: "swift-log-elk",
    platforms: [
        .macOS(.v10_15)
    ],
    products: [
        .library(name: "LoggingELK", targets: ["LoggingELK"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.0.0"),
        .package(url: "https://github.com/OpenCombine/OpenCombine.git", .upToNextMinor(from: "0.11.0"))
    ],
    targets: [
        .target(
            name: "LoggingELK",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "OpenCombine", package: "OpenCombine"),
                .product(name: "OpenCombineFoundation", package: "OpenCombine"),
                .product(name: "OpenCombineDispatch", package: "OpenCombine")
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
