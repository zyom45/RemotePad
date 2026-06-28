import Foundation
import RemotePadProtocol

public enum RemotePadAgentDefaults {
    public static let suiteName = "com.remotepad.agent"

    public static var shared: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }
}

public final class TrustedDeviceStore {
    public struct Entry: Sendable {
        public var deviceID: UUID
        public var publicKey: Data

        public init(deviceID: UUID, publicKey: Data) {
            self.deviceID = deviceID
            self.publicKey = publicKey
        }
    }

    private let defaults: UserDefaults
    private let key = "RemotePadTrustedDevicePublicKeys"

    public init(defaults: UserDefaults = RemotePadAgentDefaults.shared) {
        self.defaults = defaults
        migrateLegacyStandardValueIfNeeded()
    }

    public func publicKey(for deviceID: UUID) -> Data? {
        allKeys()[deviceID.uuidString]
    }

    public func list() -> [Entry] {
        allKeys()
            .compactMap { key, publicKey -> Entry? in
                guard let deviceID = UUID(uuidString: key) else { return nil }
                return Entry(deviceID: deviceID, publicKey: publicKey)
            }
            .sorted { $0.deviceID.uuidString < $1.deviceID.uuidString }
    }

    public func trust(publicKey: Data, for deviceID: UUID) {
        var keys = allKeys()
        keys[deviceID.uuidString] = publicKey
        defaults.set(encode(keys), forKey: key)
    }

    @discardableResult
    public func revoke(deviceID: UUID) -> Bool {
        var keys = allKeys()
        guard keys.removeValue(forKey: deviceID.uuidString) != nil else {
            return false
        }
        defaults.set(encode(keys), forKey: key)
        return true
    }

    public func removeAll() {
        defaults.removeObject(forKey: key)
    }

    private func allKeys() -> [String: Data] {
        guard let encoded = defaults.dictionary(forKey: key) as? [String: String] else {
            return [:]
        }

        return encoded.reduce(into: [String: Data]()) { result, entry in
            if let data = Data(base64Encoded: entry.value) {
                result[entry.key] = data
            }
        }
    }

    private func encode(_ keys: [String: Data]) -> [String: String] {
        keys.mapValues { $0.base64EncodedString() }
    }

    private func migrateLegacyStandardValueIfNeeded() {
        guard defaults !== UserDefaults.standard,
              defaults.object(forKey: key) == nil,
              let legacy = UserDefaults.standard.object(forKey: key) else {
            return
        }
        defaults.set(legacy, forKey: key)
    }
}

public final class PendingPairingRequestStore {
    private let defaults: UserDefaults
    private let key = "RemotePadPendingPairingRequests"

    public init(defaults: UserDefaults = RemotePadAgentDefaults.shared) {
        self.defaults = defaults
        migrateLegacyStandardValueIfNeeded()
    }

    public func identity(for deviceID: UUID) -> DeviceIdentity? {
        allRequests()[deviceID.uuidString]
    }

    public func list() -> [DeviceIdentity] {
        allRequests()
            .values
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func save(_ identity: DeviceIdentity) {
        var requests = allRequests()
        requests[identity.deviceID.uuidString] = identity
        defaults.set(encode(requests), forKey: key)
    }

    @discardableResult
    public func remove(deviceID: UUID) -> Bool {
        var requests = allRequests()
        guard requests.removeValue(forKey: deviceID.uuidString) != nil else {
            return false
        }
        defaults.set(encode(requests), forKey: key)
        return true
    }

    private func allRequests() -> [String: DeviceIdentity] {
        guard let encoded = defaults.dictionary(forKey: key) as? [String: Data] else {
            return [:]
        }

        return encoded.reduce(into: [String: DeviceIdentity]()) { result, entry in
            if let identity = try? JSONDecoder.remotePad.decode(DeviceIdentity.self, from: entry.value) {
                result[entry.key] = identity
            }
        }
    }

    private func encode(_ requests: [String: DeviceIdentity]) -> [String: Data] {
        requests.reduce(into: [String: Data]()) { result, entry in
            if let data = try? JSONEncoder.remotePad.encode(entry.value) {
                result[entry.key] = data
            }
        }
    }

    private func migrateLegacyStandardValueIfNeeded() {
        guard defaults !== UserDefaults.standard,
              defaults.object(forKey: key) == nil,
              let legacy = UserDefaults.standard.object(forKey: key) else {
            return
        }
        defaults.set(legacy, forKey: key)
    }
}
