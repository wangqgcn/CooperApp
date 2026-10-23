// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "S3Kit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "S3Kit", targets: ["S3Kit"]),
        .library(name: "SyncCore", targets: ["SyncCore"]),
        .executable(name: "s3probe", targets: ["s3probe"]),
    ],
    targets: [
        .target(name: "S3Kit"),
        // 挂载的同步逻辑：标识映射、变化序号、轮询差异。不依赖 File Provider，方便单独测试
        .target(name: "SyncCore", dependencies: ["S3Kit"]),
        .executableTarget(name: "s3probe", dependencies: ["S3Kit"]),
        .testTarget(name: "S3KitTests", dependencies: ["S3Kit"]),
        .testTarget(name: "SyncCoreTests", dependencies: ["SyncCore"]),
    ]
)
