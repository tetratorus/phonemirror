// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "phonemirror",
  platforms: [.macOS(.v14)],
  dependencies: [
    .package(url: "https://github.com/tetratorus/lightpinky.git",
             revision: "8dceaccee80c1370f26b36aaec3e97b394d0b9eb"),
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
