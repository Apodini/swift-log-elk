// swift-tools-version:5.4

import PackageDescription


let package = Package(
    name: "ApodiniTemplate",
    products: [
        .library(name: "ApodiniTemplate", targets: ["ApodiniTemplate"])
    ],
    targets: [
        .target(name: "ApodiniTemplate"),
        .testTarget(
            name: "ApodiniTemplateTests",
            dependencies: [
                .target(name: "ApodiniTemplate")
            ]
        )
    ]
)
