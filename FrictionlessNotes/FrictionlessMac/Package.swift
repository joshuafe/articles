// swift-tools-version: 5.9
// FrictionlessMac — the Mac side of the project manager (DESIGN-PM.md §8.4):
// a menu-bar Now strip and a full window with urgent priorities, projects,
// decisions and the Time view. Shares PlanCore with the iPhone app.
// Run during development with `swift run` from this folder.
import PackageDescription

let package = Package(
    name: "FrictionlessMac",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../PlanCore"),
    ],
    targets: [
        .executableTarget(
            name: "FrictionlessMac",
            dependencies: ["PlanCore"],
            resources: [.copy("Resources/DemoSeed.json")]
        ),
    ]
)
