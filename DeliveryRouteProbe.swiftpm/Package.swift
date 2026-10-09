// swift-tools-version: 5.9
import PackageDescription
import AppleProductTypes

let package = Package(
    name: "DeliveryRouteProbe",
    defaultLocalization: "ko",
    platforms: [.iOS("18.0")],
    products: [
        .iOSApplication(
            name: "DeliveryRouteProbe",
            targets: ["AppModule"],
            bundleIdentifier: "kr.deliverytools.routeprobe",
            displayVersion: "0.12.1",
            bundleVersion: "22",
            appIcon: .placeholder(icon: .map),
            accentColor: .presetColor(.green),
            supportedDeviceFamilies: [.pad, .phone],
            supportedInterfaceOrientations: [
                .portrait, .landscapeLeft, .landscapeRight,
                .portraitUpsideDown(.when(deviceFamilies: [.pad]))
            ],
            appCategory: .utilities,
            additionalInfoPlistContentFilePath: "AppInfo.plist"
        )
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            path: ".",
            exclude: ["AppInfo.plist"]
        )
    ],
    swiftLanguageVersions: [.v5]
)
