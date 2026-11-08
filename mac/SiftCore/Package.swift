// swift-tools-version:5.9
// Sift's logic, with no Apple-only frameworks, so it can be built and tested anywhere
// (swift test). The app (../Sift) adds Photos, Vision and SwiftUI on top.
import PackageDescription

let package = Package(
    name: "SiftCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "SiftCore", targets: ["SiftCore"])],
    targets: [
        .target(name: "SiftCore"),
        .testTarget(name: "SiftCoreTests", dependencies: ["SiftCore"]),
    ]
)
