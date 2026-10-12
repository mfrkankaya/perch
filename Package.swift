// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Perch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Perch",
            path: "Sources/Perch",
            swiftSettings: [.unsafeFlags(["-Osize"])],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
