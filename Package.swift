// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QbarCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "QbarCore", targets: ["QbarCore"])],
    targets: [
        .target(name: "QbarCore", path: "Core"),
        .target(name: "QbarRuntime", dependencies: ["QbarCore"], path: "App", exclude: ["QbarApp.swift"]),
        .testTarget(name: "QbarCoreTests", dependencies: ["QbarCore"], path: "Tests/QbarCoreTests"),
        .testTarget(name: "QbarRuntimeTests", dependencies: ["QbarRuntime", "QbarCore"], path: "Tests/QbarRuntimeTests")
    ]
)
