// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "WizardMobile",
  platforms: [
    .iOS(.v18),
    .macOS(.v15),
  ],
  products: [
    .library(name: "WizardDomain", targets: ["WizardDomain"]),
    .executable(name: "WizardApp", targets: ["WizardApp"]),
  ],
  targets: [
    .target(
      name: "WizardDomain",
      path: "Sources/WizardDomain"
    ),
    .executableTarget(
      name: "WizardApp",
      dependencies: ["WizardDomain"],
      path: "Sources/WizardApp"
    ),
    .testTarget(
      name: "WizardDomainTests",
      dependencies: ["WizardDomain"],
      path: "Tests/WizardDomainTests"
    ),
    .testTarget(
      name: "WizardAppTests",
      dependencies: ["WizardApp"],
      path: "Tests/WizardAppTests"
    ),
  ]
)

