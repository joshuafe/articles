// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ReminderBoard",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .iOSApplication(
            name: "ReminderBoard",
            targets: ["AppModule"],
            bundleIdentifier: "com.example.reminderboard",
            displayVersion: "1.0",
            bundleVersion: "1",
            iconAssetName: nil,
            accentColorAssetName: nil,
            supportedDeviceFamilies: [
                .pad,
                .phone
            ],
            supportedInterfaceOrientations: [
                .portrait,
                .portraitUpsideDown,
                .landscapeLeft,
                .landscapeRight
            ],
            infoPlist: [
                "NSMicrophoneUsageDescription": .string("ReminderBoard records your voice so it can create reminders."),
                "NSAppTransportSecurity": .dictionary([
                    "NSAllowsArbitraryLoads": .boolean(true)
                ])
            ]
        )
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            path: "Sources/AppModule",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
