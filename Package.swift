// swift-tools-version: 5.10
import Foundation
import PackageDescription

// Embedding Info.plist gives `swift run` builds the same bundle id, local-network
// usage string and http allowance as the packaged Clippy.app.
let infoPlist = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("Support/Info.plist").path

let package = Package(
    name: "Clippy",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Clippy",
            path: "Sources/Clippy",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                              "-Xlinker", "__info_plist", "-Xlinker", infoPlist])
            ]
        )
    ]
)
