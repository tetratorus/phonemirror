// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "phonemirror",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(url: "https://github.com/tetratorus/lightpinky.git",
             revision: "3568cd7b4f3877a6781817afb7c089ccbce3668d"),
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
