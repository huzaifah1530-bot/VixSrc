// swift-tools-version: 6.0
// Speaker-split test bench for auto captions. Runs the same Sortformer
// model the iOS app uses over real audio with known subtitles and scores
// how well speaker changes line up. Not part of the app.
import PackageDescription

let package = Package(
    name: "CaptionLab",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.18.4")
    ],
    targets: [
        .executableTarget(
            name: "CaptionLab",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources"
        )
    ]
)
