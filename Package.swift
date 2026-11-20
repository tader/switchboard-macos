// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "SwitchboardMac", platforms: [.macOS(.v14)], products: [.executable(name: "SwitchboardMenu", targets: ["SwitchboardMenu"])], targets: [.target(name: "ManagerKit"), .executableTarget(name: "SwitchboardMenu", dependencies: ["ManagerKit"]), .testTarget(name: "ManagerKitTests", dependencies: ["ManagerKit"])])
