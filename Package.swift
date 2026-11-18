// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DeusIsolation",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "DeusIsolation", targets: ["DeusIsolation"]),
        .executable(name: "deus-airlock-policy", targets: ["DeusPolicyInspector"]),
    ],
    targets: [
        .target(name: "DeusIsolation", path: "Library/Isolation"),
        .target(name: "DeusLinks", path: "Library/Links"),
        .executableTarget(name: "DeusPolicyInspector", dependencies: ["DeusIsolation"], path: "Tools/PolicyInspector"),
        .testTarget(name: "DeusIsolationTests", dependencies: ["DeusIsolation"], path: "Tests/Isolation"),
        .testTarget(name: "DeusLinksTests", dependencies: ["DeusLinks"], path: "Tests/Links"),
    ]
)
