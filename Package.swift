// swift-tools-version:5.9
import PackageDescription

// One package, three targets:
//  - LidAngleKit : pure sensor-reading layer. Never touches AppKit, so both the
//                  CLI and the menu bar app can use it.
//  - lidangle    : the discovery / verification command line tool.
//  - MacBookUno  : the menu bar app (AppKit) with the lid fold effect.
let package = Package(
    name: "MacBookUno",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "LidAngleKit", targets: ["LidAngleKit"]),
        .executable(name: "lidangle", targets: ["lidangle"]),
        .executable(name: "MacBookUno", targets: ["MacBookUno"]),
    ],
    targets: [
        .target(name: "LidAngleKit"),
        .executableTarget(name: "lidangle", dependencies: ["LidAngleKit"]),
        .executableTarget(name: "MacBookUno", dependencies: ["LidAngleKit"]),
    ]
)
