// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "OuraSync",
  platforms: [.iOS(.v17), .macOS(.v14)],
  products: [.library(name: "OuraProtocol", targets: ["OuraProtocol"])],
  targets: [
    .target(name: "OuraProtocol"),
    .testTarget(name: "OuraProtocolTests", dependencies: ["OuraProtocol"]),
  ]
)
