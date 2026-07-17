import CryptoKit
import Foundation
import RemotePadProtocol

public enum SecureSessionRole: Sendable {
    case client
    case server
}

public enum SecureSessionError: Error, Equatable {
    case invalidPublicKey
    case invalidEnvelope
    case unexpectedCounter(expected: UInt64, received: UInt64)
    case authenticationFailed
}

public struct SessionKeyExchange: Sendable {
    public let privateKey: Curve25519.KeyAgreement.PrivateKey

    public init() {
        self.privateKey = Curve25519.KeyAgreement.PrivateKey()
    }

    public var publicKey: Data {
        privateKey.publicKey.rawRepresentation
    }
}

public struct SecureFrameHeader: Codable, Equatable, Sendable {
    public var kind: String
    public var counter: UInt64

    public init(counter: UInt64) {
        self.kind = "secure.frame"
        self.counter = counter
    }
}

public final class SecureSession: @unchecked Sendable {
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private let sendNoncePrefix: Data
    private let receiveNoncePrefix: Data
    private let sendAADPrefix: Data
    private let receiveAADPrefix: Data
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0

    public init(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        remotePublicKey: Data,
        clientNonce: Data,
        serverNonce: Data,
        role: SecureSessionRole
    ) throws {
        guard let remoteKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: remotePublicKey) else {
            throw SecureSessionError.invalidPublicKey
        }
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: remoteKey)
        let salt = clientNonce + serverNonce
        let keyMaterial = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data("RemotePad secure session v2".utf8),
            outputByteCount: 64
        )
        let bytes = keyMaterial.withUnsafeBytes { Data($0) }
        let clientToServer = SymmetricKey(data: bytes.prefix(32))
        let serverToClient = SymmetricKey(data: bytes.suffix(32))

        switch role {
        case .client:
            sendKey = clientToServer
            receiveKey = serverToClient
            sendNoncePrefix = Data([0x43, 0x32, 0x53, 0x00])
            receiveNoncePrefix = Data([0x53, 0x32, 0x43, 0x00])
            sendAADPrefix = Data("RPAD-C2S-v2".utf8)
            receiveAADPrefix = Data("RPAD-S2C-v2".utf8)
        case .server:
            sendKey = serverToClient
            receiveKey = clientToServer
            sendNoncePrefix = Data([0x53, 0x32, 0x43, 0x00])
            receiveNoncePrefix = Data([0x43, 0x32, 0x53, 0x00])
            sendAADPrefix = Data("RPAD-S2C-v2".utf8)
            receiveAADPrefix = Data("RPAD-C2S-v2".utf8)
        }
    }

    public func seal(frame: Frame) throws -> Data {
        let counter = sendCounter
        let plaintext = try FrameCodec.encode(frame)
        let sealed = try ChaChaPoly.seal(
            plaintext,
            using: sendKey,
            nonce: try nonce(prefix: sendNoncePrefix, counter: counter),
            authenticating: associatedData(prefix: sendAADPrefix, counter: counter)
        )
        sendCounter &+= 1

        return try FrameCodec.encodeHeader(
            SecureFrameHeader(counter: counter),
            type: .data,
            channelID: 0,
            payload: sealed.ciphertext + sealed.tag
        )
    }

    public func open(frame: Frame) throws -> Frame {
        let header = try FrameCodec.decodeHeader(SecureFrameHeader.self, from: frame)
        guard header.kind == "secure.frame", frame.payload.count >= 16 else {
            throw SecureSessionError.invalidEnvelope
        }
        guard header.counter == receiveCounter else {
            throw SecureSessionError.unexpectedCounter(expected: receiveCounter, received: header.counter)
        }

        let ciphertext = frame.payload.dropLast(16)
        let tag = frame.payload.suffix(16)
        let nonce = try nonce(prefix: receiveNoncePrefix, counter: header.counter)
        let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        let plaintext: Data
        do {
            plaintext = try ChaChaPoly.open(
                box,
                using: receiveKey,
                authenticating: associatedData(prefix: receiveAADPrefix, counter: header.counter)
            )
        } catch {
            throw SecureSessionError.authenticationFailed
        }
        receiveCounter &+= 1
        return try FrameCodec.decode(plaintext)
    }

    private func nonce(prefix: Data, counter: UInt64) throws -> ChaChaPoly.Nonce {
        try ChaChaPoly.Nonce(data: prefix + encoded(counter))
    }

    private func associatedData(prefix: Data, counter: UInt64) -> Data {
        prefix + encoded(counter)
    }

    private func encoded(_ value: UInt64) -> Data {
        Data([
            UInt8((value >> 56) & 0xff), UInt8((value >> 48) & 0xff),
            UInt8((value >> 40) & 0xff), UInt8((value >> 32) & 0xff),
            UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff), UInt8(value & 0xff)
        ])
    }
}
