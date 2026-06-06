// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RemotePad",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "RemotePadProtocol",
            targets: ["RemotePadProtocol"]
        ),
        .executable(
            name: "remotepad-agent",
            targets: ["RemotePadAgent"]
        ),
        .executable(
            name: "remotepad-dev-client",
            targets: ["RemotePadDevClient"]
        )
    ],
    targets: [
        .target(
            name: "RemotePadProtocol",
            path: "packages/RemotePadProtocol/Sources"
        ),
        .executableTarget(
            name: "RemotePadAgent",
            dependencies: ["RemotePadProtocol"],
            path: "apps/mac-agent/Sources"
        ),
        .executableTarget(
            name: "RemotePadDevClient",
            dependencies: ["RemotePadProtocol"],
            path: "tools/dev-client/Sources"
        ),
        .testTarget(
            name: "RemotePadProtocolTests",
            dependencies: ["RemotePadProtocol"],
            path: "packages/RemotePadProtocol/Tests"
        )
    ]
)
