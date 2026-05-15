// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Wizard-Block-Of-Truth",
  platforms: [
    .iOS(.v18),
    .macOS(.v15),
  ],
  products: [
    .library(name: "WizardDomain", targets: ["WizardDomain"]),
    .library(name: "WizardNet", targets: ["WizardNet"]),
    .executable(name: "WizardApp", targets: ["WizardApp"]),
  ],
  targets: [
    .target(
      name: "WizardDomain",
      path: "Sources/WizardDomain"
    ),
    .target(
      name: "WizardNet",
      dependencies: ["WizardDomain"],
      path: "Sources/WizardNet"
    ),
    .executableTarget(
      name: "WizardApp",
      dependencies: ["WizardDomain", "WizardNet"],
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
    .testTarget(
      name: "WizardNetTests",
      dependencies: ["WizardNet", "WizardDomain"],
      path: "Tests/WizardNetTests"
    ),
  ]
)

