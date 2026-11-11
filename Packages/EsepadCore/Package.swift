// swift-tools-version: 5.9
import PackageDescription

// esepad の「画面に依存しない部分」。iPhone と Mac の両方が読み込み、macOS 上の swift test で固める。
let package = Package(
    name: "EsepadCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "EsepadCore", targets: ["EsepadCore"]),
    ],
    targets: [
        .target(name: "EsepadCore"),
        .testTarget(name: "EsepadCoreTests", dependencies: ["EsepadCore"]),
    ]
)
