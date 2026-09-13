// swift-tools-version:5.3
import PackageDescription

let package = Package(
    name: "FitFindCore",
    platforms: [.macOS(.v10_15)],
    products: [.library(name: "FitFindCore", targets: ["FitFindCore"])],
    targets: [
        .target(name: "FitFindCore", path: "FitFind/Core"),
        .testTarget(name: "FitFindCoreTests", dependencies: ["FitFindCore"], path: "Tests")
    ]
)
