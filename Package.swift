// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Airtype",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Airtype", targets: ["Airtype"])
    ],
    dependencies: [
        .package(url: "https://github.com/soffes/HotKey.git", from: "0.2.0"),
        .package(url: "https://github.com/alta/swift-opus.git", exact: "0.0.2")
    ],
    targets: [
        .executableTarget(
            name: "Airtype",
            dependencies: ["HotKey", .product(name: "Copus", package: "swift-opus")],
            path: "Sources"
        )
    ]
)
