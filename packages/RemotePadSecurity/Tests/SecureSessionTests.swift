import Foundation
import RemotePadProtocol
import RemotePadSecurity
import Testing

@Test func secureSessionRoundTripsFramesInBothDirections() throws {
    let clientExchange = SessionKeyExchange()
    let serverExchange = SessionKeyExchange()
    let clientNonce = Data(repeating: 0x11, count: 32)
    let serverNonce = Data(repeating: 0x22, count: 32)
    let client = try SecureSession(
        privateKey: clientExchange.privateKey,
        remotePublicKey: serverExchange.publicKey,
        clientNonce: clientNonce,
        serverNonce: serverNonce,
        role: .client
    )
    let server = try SecureSession(
        privateKey: serverExchange.privateKey,
        remotePublicKey: clientExchange.publicKey,
        clientNonce: clientNonce,
        serverNonce: serverNonce,
        role: .server
    )

    let request = Frame(
        type: .data,
        channelID: 2,
        requestID: 7,
        header: Data(#"{"kind":"terminal.input"}"#.utf8),
        payload: Data("pwd\n".utf8)
    )
    let requestEnvelope = try FrameCodec.decode(client.seal(frame: request))
    #expect(try server.open(frame: requestEnvelope) == request)

    let response = Frame(
        type: .data,
        channelID: 2,
        header: Data(#"{"kind":"terminal.output"}"#.utf8),
        payload: Data("/Users/nao\n".utf8)
    )
    let responseEnvelope = try FrameCodec.decode(server.seal(frame: response))
    #expect(try client.open(frame: responseEnvelope) == response)
}

@Test func secureSessionRejectsReplay() throws {
    let clientExchange = SessionKeyExchange()
    let serverExchange = SessionKeyExchange()
    let clientNonce = Data(repeating: 0x33, count: 32)
    let serverNonce = Data(repeating: 0x44, count: 32)
    let client = try SecureSession(
        privateKey: clientExchange.privateKey,
        remotePublicKey: serverExchange.publicKey,
        clientNonce: clientNonce,
        serverNonce: serverNonce,
        role: .client
    )
    let server = try SecureSession(
        privateKey: serverExchange.privateKey,
        remotePublicKey: clientExchange.publicKey,
        clientNonce: clientNonce,
        serverNonce: serverNonce,
        role: .server
    )
    let envelope = try FrameCodec.decode(client.seal(frame: Frame(type: .ping, channelID: 1)))

    _ = try server.open(frame: envelope)
    #expect(throws: SecureSessionError.unexpectedCounter(expected: 1, received: 0)) {
        _ = try server.open(frame: envelope)
    }
}
