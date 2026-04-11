// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Terminatab",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-testing.git", branch: "release/6.2"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.13.0"),
    ],
    targets: [
        .executableTarget(
            name: "Terminatab",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
        .testTarget(
            name: "TerminatabTests",
            dependencies: [
                "Terminatab",
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ]
)
