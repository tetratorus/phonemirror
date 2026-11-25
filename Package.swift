// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "phonemirror",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(path: "../lightpinky"),
  ],
  targets: [
    .executableTarget(
      name: "phonemirror",
      dependencies: [.product(name: "LightpinkyCore", package: "lightpinky")],
      linkerSettings: [
        .unsafeFlags([
          "-F/Library/Developer/PrivateFrameworks",
          "-framework", "CoreDevice",
          "-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/PrivateFrameworks",
        ]),
      ]
    ),
  ]
)
