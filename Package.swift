// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PortForwardingApp",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PortForwardingLib", targets: ["PortForwardingLib"]),
        .executable(name: "PortForwardingApp", targets: ["PortForwardingApp"]),
    ],
    targets: [
        .target(
            name: "PortForwardingLib",
            path: "Sources",
            exclude: ["App", "TestRunner"],
            sources: ["Domain", "Process"]
        ),
        .executableTarget(
            name: "PortForwardingApp",
            dependencies: ["PortForwardingLib"],
            path: "Sources/App"
        ),
        .executableTarget(
            name: "TestRunner",
            dependencies: ["PortForwardingLib"],
            path: "Sources/TestRunner"
        ),
        .testTarget(
            name: "DomainTests",
            dependencies: ["PortForwardingLib"],
            path: "Tests/DomainTests"
        ),
        .testTarget(
            name: "ProcessTests",
            dependencies: ["PortForwardingLib"],
            path: "Tests/ProcessTests"
        ),
    ]
)
