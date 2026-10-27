// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Jetway",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Jetway",
            path: "Sources/Jetway",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
