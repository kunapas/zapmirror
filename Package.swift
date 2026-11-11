// swift-tools-version:6.0
//
// Zapmirror (private): show and control an Android phone on a Mac. See docs/MIRRORING-PLAN.md.
//   Scripts/build-app.sh        the app, in dist/Zapmirror.app
//   Scripts/test.sh             the tests (plain `swift test` with full Xcode)

import PackageDescription

var products: [Product] = [
    .library(name: "ZapmirrorPhone", targets: ["ZapmirrorPhone", "ZapmirrorADB"]),
]

var targets: [Target] = [
    // Talks to the adb server (localhost:5037): list phones, push files, run commands, open sockets on the phone.
    .target(name: "ZapmirrorADB"),
    // The Mac side of Zapmirror's phone protocol: starting the phone component (Phone/), its video and audio
    // streams, and control messages (docs/PHONE-PROTOCOL.md).
    .target(name: "ZapmirrorPhone", dependencies: ["ZapmirrorADB"]),
    .testTarget(name: "ZapmirrorPhoneTests", dependencies: ["ZapmirrorPhone", "ZapmirrorADB"]),
]

#if os(macOS)
targets.append(.executableTarget(name: "ZapmirrorApp",
                                 dependencies: ["ZapmirrorPhone", "ZapmirrorADB"],
                                 path: "App/Zapmirror",
                                 exclude: ["AppIcon.icns"])) // copied into the bundle by Scripts/build-app.sh
products.append(.executable(name: "ZapmirrorApp", targets: ["ZapmirrorApp"]))
#endif

let package = Package(
    name: "Zapmirror",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
