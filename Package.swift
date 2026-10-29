// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FOXmin",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "FOXmin",
            path: "Sources/FOXmin",
            linkerSettings: [
                // SkyLight es el framework privado del WindowServer. Lo usamos para
                // activar ventanas de forma confiable (igual que AltTab o yabai).
                .unsafeFlags(["-F/System/Library/PrivateFrameworks", "-framework", "SkyLight"])
            ]
        )
    ]
)
