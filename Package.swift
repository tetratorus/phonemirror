// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "phonemirror",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(url: "https://github.com/tetratorus/lightpinky.git",
             revision: "bb57b0574e3a1a2a8218141e46d1bc1628341285"),
  ],
  targets: [
    .target(name: "PhoneMirrorKit"),
    .executableTarget(
      name: "phonemirror",
      dependencies: ["PhoneMirrorKit", .product(name: "LightpinkyCore", package: "lightpinky")],
      linkerSettings: [
        .unsafeFlags([
          "-F/Library/Developer/PrivateFrameworks",
          "-framework", "CoreDevice",
          "-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/PrivateFrameworks",
        ]),
      ]
    ),
    .testTarget(name: "PhoneMirrorKitTests", dependencies: ["PhoneMirrorKit"]),
  ]
)
