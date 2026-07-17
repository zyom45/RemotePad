import Foundation
import CryptoKit
import Testing
@testable import RemotePadProtocol

@Test func deviceIdentityRoundTripsThroughJSONHeader() throws {
    let identity = DeviceIdentity.fixture(deviceType: .ipad)
    let message = PairingStart(identity: identity)

    let encoded = try FrameCodec.encodeHeader(
        message,
        type: .request,
        channelID: 1,
        requestID: 1
    )
    let frame = try FrameCodec.decode(encoded)
    let decoded = try FrameCodec.decodeHeader(PairingStart.self, from: frame)

    #expect(decoded == message)
    #expect(decoded.kind == "pairing.start")
}

@Test func pairingResultRoundTrips() throws {
    let result = PairingResult(
        accepted: true,
        status: "pending_approval",
        deviceID: UUID(uuidString: "00000000-0000-0000-0000-0000000000aa")!,
        permissions: .mvpDefault
    )

    let frame = try FrameCodec.decode(
        try FrameCodec.encodeHeader(result, type: .response, channelID: 1, requestID: 2)
    )
    let decoded = try FrameCodec.decodeHeader(PairingResult.self, from: frame)

    #expect(decoded == result)
    #expect(decoded.kind == "pairing.result")
}

@Test func pairingStatusRequestRoundTrips() throws {
    let request = PairingStatusRequest(
        deviceID: UUID(uuidString: "00000000-0000-0000-0000-0000000000aa")!
    )

    let frame = try FrameCodec.decode(
        try FrameCodec.encodeHeader(request, type: .request, channelID: 1, requestID: 3)
    )
    let decoded = try FrameCodec.decodeHeader(PairingStatusRequest.self, from: frame)

    #expect(decoded == request)
    #expect(decoded.kind == "pairing.status")
}

@Test func pairingTranscriptCanBeSignedAndVerified() throws {
    let privateKey = Curve25519.Signing.PrivateKey()
    let identity = DeviceIdentity(
        deviceID: UUID(uuidString: "00000000-0000-0000-0000-0000000000aa")!,
        deviceName: "Test iPad",
        deviceType: .ipad,
        publicKey: privateKey.publicKey.rawRepresentation,
        createdAt: Date(timeIntervalSince1970: 1_800_000_000)
    )
    let transcript = PairingTranscript.make(
        challenge: Data([0x01, 0x02, 0x03]),
        ipadIdentity: identity,
        macDeviceID: UUID(uuidString: "00000000-0000-0000-0000-0000000000bb")!,
        macPublicKey: Data(repeating: 0xbb, count: 32)
    )

    let signature = try privateKey.signature(for: transcript)

    #expect(privateKey.publicKey.isValidSignature(signature, for: transcript))
    #expect(!privateKey.publicKey.isValidSignature(signature, for: transcript + Data([0xff])))
}

@Test func sessionHandshakeMessagesRoundTrip() throws {
    let deviceID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let nonce = Data([1, 2, 3, 4])
    let publicKey = Data(repeating: 0xaa, count: 32)
    let keyAgreementPublicKey = Data(repeating: 0xbb, count: 32)
    let hello = ClientHello(
        deviceID: deviceID,
        nonce: nonce,
        publicKey: publicKey,
        keyAgreementPublicKey: keyAgreementPublicKey
    )

    let clientFrame = try FrameCodec.decode(
        try FrameCodec.encodeHeader(hello, type: .request, channelID: 1)
    )
    let decodedHello = try FrameCodec.decodeHeader(ClientHello.self, from: clientFrame)

    #expect(decodedHello == hello)
    #expect(decodedHello.publicKey == publicKey)

    let server = ServerHello(
        deviceID: deviceID,
        nonce: Data([5, 6, 7, 8]),
        capabilities: .mvp,
        identityPublicKey: publicKey,
        keyAgreementPublicKey: Data(repeating: 0xcc, count: 32),
        signature: Data(repeating: 0xdd, count: 64)
    )
    let serverFrame = try FrameCodec.decode(
        try FrameCodec.encodeHeader(server, type: .response, channelID: 1)
    )
    let decodedServer = try FrameCodec.decodeHeader(ServerHello.self, from: serverFrame)

    #expect(decodedServer == server)
    #expect(decodedServer.capabilities.channels.contains(.browserProxy))
}

@Test func authTranscriptIsDeterministic() {
    let clientDeviceID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let serverDeviceID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    let first = AuthTranscript.make(
        clientDeviceID: clientDeviceID,
        clientNonce: Data([0x01, 0x02]),
        serverDeviceID: serverDeviceID,
        serverNonce: Data([0x03, 0x04]),
        clientKeyAgreementPublicKey: Data(repeating: 0x05, count: 32),
        serverKeyAgreementPublicKey: Data(repeating: 0x06, count: 32)
    )
    let second = AuthTranscript.make(
        clientDeviceID: clientDeviceID,
        clientNonce: Data([0x01, 0x02]),
        serverDeviceID: serverDeviceID,
        serverNonce: Data([0x03, 0x04]),
        clientKeyAgreementPublicKey: Data(repeating: 0x05, count: 32),
        serverKeyAgreementPublicKey: Data(repeating: 0x06, count: 32)
    )

    #expect(first == second)
    #expect(first != Data([0x01, 0x02, 0x03, 0x04]))
}

@Test func authTranscriptCanBeSignedAndVerified() throws {
    let privateKey = Curve25519.Signing.PrivateKey()
    let publicKey = privateKey.publicKey
    let transcript = AuthTranscript.make(
        clientDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        clientNonce: Data([0x01, 0x02]),
        serverDeviceID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        serverNonce: Data([0x03, 0x04]),
        clientKeyAgreementPublicKey: Data(repeating: 0x05, count: 32),
        serverKeyAgreementPublicKey: Data(repeating: 0x06, count: 32)
    )

    let signature = try privateKey.signature(for: transcript)

    #expect(publicKey.isValidSignature(signature, for: transcript))
    #expect(!publicKey.isValidSignature(signature, for: transcript + Data([0xff])))
}

@Test func permissionsDefaultMatchesMVP() {
    let permissions = Permissions.mvpDefault

    #expect(permissions.terminal)
    #expect(permissions.browserProxy)
    #expect(permissions.devtools)
    #expect(!permissions.clipboard)
    #expect(!permissions.screen)
    #expect(!permissions.audio)
}

@Test func authResultCanRepresentRejection() throws {
    let rejected = AuthResult(
        accepted: false,
        sessionID: nil,
        permissions: nil,
        reason: "not paired"
    )

    let frame = try FrameCodec.decode(
        try FrameCodec.encodeHeader(rejected, type: .response, channelID: 1)
    )
    let decoded = try FrameCodec.decodeHeader(AuthResult.self, from: frame)

    #expect(decoded == rejected)
    #expect(decoded.reason == "not paired")
}

@Test func protocolErrorCanDescribeVersionMismatch() throws {
    let error = ProtocolErrorMessage(
        code: "protocol_version_unsupported",
        message: "Client does not support protocol 1.",
        requestID: 1,
        supportedProtocols: [1],
        minimumSupportedProtocol: 1
    )

    let frame = try FrameCodec.decode(
        try FrameCodec.encodeHeader(error, type: .error, flags: [.error], channelID: 1, requestID: 1)
    )
    let decoded = try FrameCodec.decodeHeader(ProtocolErrorMessage.self, from: frame)

    #expect(decoded == error)
    #expect(decoded.supportedProtocols == [1])
    #expect(decoded.minimumSupportedProtocol == 1)
}

private extension DeviceIdentity {
    static func fixture(deviceType: DeviceType) -> DeviceIdentity {
        DeviceIdentity(
            deviceID: UUID(uuidString: "00000000-0000-0000-0000-0000000000aa")!,
            deviceName: "Test Device",
            deviceType: deviceType,
            publicKey: Data([0xaa, 0xbb, 0xcc]),
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }
}
