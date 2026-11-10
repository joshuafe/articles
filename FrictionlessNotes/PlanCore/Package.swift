// swift-tools-version: 5.9
// PlanCore — the project-manager layer shared by the iPhone app and the Mac app
// (DESIGN-PM.md): value types, the Tier-0 urgency engine, the JSON ledger and
// the seed importer. No UI, no SwiftData: those stay in the apps.
import PackageDescription

let package = Package(
    name: "PlanCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PlanCore", targets: ["PlanCore"]),
    ],
    targets: [
        .target(name: "PlanCore"),
        .testTarget(name: "PlanCoreTests", dependencies: ["PlanCore"]),
    ]
)
