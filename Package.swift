// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ChessKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ChessKit", targets: ["ChessKit"])
    ],
    targets: [
        .target(
            name: "ChessKit",
            resources: [.process("Resources/Pieces.xcassets")]
        ),
        .testTarget(
            name: "ChessKitTests",
            dependencies: ["ChessKit"]
        )
    ]
)
