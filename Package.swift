// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PowvyNote",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "PowvyNoteCore", targets: ["PowvyNoteCore"])], // used by ios/ (iPad app)
    targets: [
        .target(name: "PowvyNoteCore"),
        .executableTarget(name: "PowvyNote", dependencies: ["PowvyNoteCore"]),
        // `swift run SelfCheck` — CLT has no XCTest, so plain asserts.
        .executableTarget(name: "SelfCheck", dependencies: ["PowvyNoteCore"]),
        .executableTarget(name: "SyncCheck", dependencies: ["PowvyNoteCore"]),
    ]
)
