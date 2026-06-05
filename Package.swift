// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexAccountSwitcher",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CodexAccountSwitcher", targets: ["CodexAccountSwitcher"])
    ],
    targets: [
        .executableTarget(
            name: "CodexAccountSwitcher",
            path: "Sources",
            exclude: [
                "icon.png",
                "toolbar-icon.png"
            ],
            sources: [
                "main.swift"
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("UserNotifications")
            ]
        )
    ]
)
