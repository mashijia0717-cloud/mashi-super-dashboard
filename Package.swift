// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CPAQuotaBar",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CPAQuotaBar", targets: ["CPAQuotaBar"])],
    targets: [
        .executableTarget(
            name: "CPAQuotaBar",
            path: "Sources/CPAQuotaBar",
            resources: [
                .copy("Resources/libimobiledevice"),
                .copy("Resources/9ROUTER_LICENSE.txt"),
                .copy("Resources/AppIcon.png"),
                .copy("Resources/MaShiDashboard.icns")
            ],
            linkerSettings: [
                .linkedFramework("IOKit")
            ]
        ),
        .testTarget(
            name: "CPAQuotaBarTests",
            dependencies: ["CPAQuotaBar"],
            path: "Tests/CPAQuotaBarTests"
        )
    ]
)
