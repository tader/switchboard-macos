// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwitchboardMac",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "SwitchboardMenu", targets: ["SwitchboardMenu"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")],
    targets: [
        .target(name: "ManagerKit", dependencies: [.product(name: "Sparkle", package: "Sparkle")]),
        .executableTarget(name: "SwitchboardMenu", dependencies: ["ManagerKit"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "ManagerKitTests", dependencies: ["ManagerKit"])
    ]
)
