// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Cockpit",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Cockpit", targets: ["Cockpit"])
    ],
    targets: [
        .executableTarget(
            name: "Cockpit",
            path: "Sources/Cockpit",
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))]
        )
    ]
)
