import CryptoKit
import Foundation
import Security

public enum RemotePadSecurityError: Error, Equatable {
    case keychain(OSStatus)
    case invalidIdentity
}

public struct DeviceKeyIdentity: Sendable {
    public let deviceID: UUID
    public let privateKey: Curve25519.Signing.PrivateKey

    public var publicKey: Data {
        privateKey.publicKey.rawRepresentation
    }

    public init(deviceID: UUID, privateKey: Curve25519.Signing.PrivateKey) {
        self.deviceID = deviceID
        self.privateKey = privateKey
    }

    public func sign(_ data: Data) throws -> Data {
        try privateKey.signature(for: data)
    }

    public static func loadOrCreate(
        service: String,
        legacyDefaults: UserDefaults? = nil,
        legacyDeviceIDKey: String? = nil,
        legacyPrivateKeyKey: String? = nil
    ) throws -> DeviceKeyIdentity {
        let keychain = KeychainDataStore(service: service)
        if let stored = try keychain.data(for: storageAccount) {
            return try decode(stored)
        }

        let identity = migratedIdentity(
            defaults: legacyDefaults,
            deviceIDKey: legacyDeviceIDKey,
            privateKeyKey: legacyPrivateKeyKey
        ) ?? DeviceKeyIdentity(deviceID: UUID(), privateKey: Curve25519.Signing.PrivateKey())

        try keychain.set(try encode(identity), for: storageAccount)
        if let legacyDefaults {
            if let legacyDeviceIDKey { legacyDefaults.removeObject(forKey: legacyDeviceIDKey) }
            if let legacyPrivateKeyKey { legacyDefaults.removeObject(forKey: legacyPrivateKeyKey) }
        }
        return identity
    }

    public static func loadOrCreate(fileURL: URL) throws -> DeviceKeyIdentity {
        if let data = try? Data(contentsOf: fileURL) {
            return try decode(data)
        }

        let identity = DeviceKeyIdentity(deviceID: UUID(), privateKey: Curve25519.Signing.PrivateKey())
        let data = try encode(identity)
        try data.write(to: fileURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: fileURL.path
        )
        return identity
    }

    private static let storageAccount = "device-identity-v1"

    private struct StoredIdentity: Codable {
        let deviceID: UUID
        let privateKey: Data
    }

    private static func encode(_ identity: DeviceKeyIdentity) throws -> Data {
        try JSONEncoder().encode(
            StoredIdentity(deviceID: identity.deviceID, privateKey: identity.privateKey.rawRepresentation)
        )
    }

    private static func decode(_ data: Data) throws -> DeviceKeyIdentity {
        guard let stored = try? JSONDecoder().decode(StoredIdentity.self, from: data),
              let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: stored.privateKey) else {
            throw RemotePadSecurityError.invalidIdentity
        }
        return DeviceKeyIdentity(deviceID: stored.deviceID, privateKey: privateKey)
    }

    private static func migratedIdentity(
        defaults: UserDefaults?,
        deviceIDKey: String?,
        privateKeyKey: String?
    ) -> DeviceKeyIdentity? {
        guard let defaults,
              let deviceIDKey,
              let deviceIDValue = defaults.string(forKey: deviceIDKey),
              let deviceID = UUID(uuidString: deviceIDValue) else {
            return nil
        }

        if let privateKeyKey,
           let privateKeyValue = defaults.string(forKey: privateKeyKey),
           let privateKeyData = Data(base64Encoded: privateKeyValue),
           let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData) {
            return DeviceKeyIdentity(deviceID: deviceID, privateKey: privateKey)
        }

        return DeviceKeyIdentity(deviceID: deviceID, privateKey: Curve25519.Signing.PrivateKey())
    }
}

public struct KeychainDataStore: Sendable {
    public let service: String

    public init(service: String) {
        self.service = service
    }

    public func data(for account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw RemotePadSecurityError.keychain(status) }
        guard let data = item as? Data else { throw RemotePadSecurityError.invalidIdentity }
        return data
    }

    public func set(_ data: Data, for account: String) throws {
        let query = baseQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw RemotePadSecurityError.keychain(updateStatus)
        }

        var insertion = query
        attributes.forEach { insertion[$0.key] = $0.value }
        let addStatus = SecItemAdd(insertion as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw RemotePadSecurityError.keychain(addStatus) }
    }

    public func remove(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw RemotePadSecurityError.keychain(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
    }
}
