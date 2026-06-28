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
        .library(
            name: "RemotePadAgentSupport",
            targets: ["RemotePadAgentSupport"]
        ),
        .executable(
            name: "remotepad-agent",
            targets: ["RemotePadAgent"]
        ),
        .executable(
            name: "remotepad-pairing-approver",
            targets: ["RemotePadPairingApprover"]
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
        .target(
            name: "RemotePadAgentSupport",
            dependencies: ["RemotePadProtocol"],
            path: "packages/RemotePadAgentSupport/Sources"
        ),
        .executableTarget(
            name: "RemotePadAgent",
            dependencies: ["RemotePadProtocol", "RemotePadAgentSupport"],
            path: "apps/mac-agent/Sources"
        ),
        .executableTarget(
            name: "RemotePadPairingApprover",
            dependencies: ["RemotePadProtocol", "RemotePadAgentSupport"],
            path: "apps/mac-pairing-approver/Sources"
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
        ),
        .testTarget(
            name: "RemotePadAgentSupportTests",
            dependencies: ["RemotePadAgentSupport"],
            path: "packages/RemotePadAgentSupport/Tests"
        )
    ]
)
