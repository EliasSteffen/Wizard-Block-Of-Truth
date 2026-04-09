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
  ],
  targets: [
    .target(
      name: "WizardDomain",
      path: "Sources/WizardDomain"
    ),
    .testTarget(
      name: "WizardDomainTests",
      dependencies: ["WizardDomain"],
      path: "Tests/WizardDomainTests"
    ),
  ]
)

