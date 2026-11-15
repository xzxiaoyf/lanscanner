// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LANScanner",
    platforms: [.macOS(.v11)],
    products: [
        .executable(name: "LANScanner", targets: ["LANScanner"])
    ],
    targets: [
        .executableTarget(
            name: "LANScanner",
            path: "Sources/LANScanner"
        )
    ]
)
