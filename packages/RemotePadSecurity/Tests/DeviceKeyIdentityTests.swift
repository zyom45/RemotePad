import CryptoKit
import Foundation
import RemotePadSecurity
import Testing

@Test func deviceIdentitySignsWithItsPublicKey() throws {
    let identity = DeviceKeyIdentity(deviceID: UUID(), privateKey: Curve25519.Signing.PrivateKey())
    let message = Data("RemotePad".utf8)
    let signature = try identity.sign(message)

    #expect(identity.privateKey.publicKey.isValidSignature(signature, for: message))
    #expect(identity.publicKey == identity.privateKey.publicKey.rawRepresentation)
}
