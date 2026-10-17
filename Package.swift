// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "OrderCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "OrderCore", targets: ["OrderCore"])],
    targets: [
        .target(name: "OrderCore"),
        .testTarget(name: "OrderCoreTests", dependencies: ["OrderCore"])
    ]
)
