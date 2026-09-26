// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "BindersKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "BindersKit", targets: ["BindersKit"]),
    ],
    targets: [
        .target(name: "BindersKit"),
        .testTarget(name: "BindersKitTests", dependencies: ["BindersKit"]),
    ]
)
