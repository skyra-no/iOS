// swift-tools-version: 5.9

// SwiftPM reads this manifest to build the SDK, include its privacy resource, and discover its tests.
import PackageDescription

let package = Package(
    name: "Skyra",
    platforms: [.iOS(.v15), .macOS(.v10_15)],
    products: [
        .library(name: "Skyra", targets: ["Skyra"]),
    ],
    targets: [
        .target(name: "Skyra", resources: [.copy("PrivacyInfo.xcprivacy")]),
        .testTarget(name: "SkyraTests", dependencies: ["Skyra"]),
    ],
    swiftLanguageVersions: [.v5]
)
