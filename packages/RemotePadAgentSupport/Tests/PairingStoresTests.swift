import Foundation
import Testing
@testable import RemotePadAgentSupport
import RemotePadProtocol

@Test func trustedDeviceStorePersistsListsAndRevokesDevices() {
    let defaults = isolatedDefaults()
    let store = TrustedDeviceStore(defaults: defaults)
    let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    store.trust(publicKey: Data([0x02]), for: firstID)
    store.trust(publicKey: Data([0x01]), for: secondID)

    #expect(store.publicKey(for: firstID) == Data([0x02]))
    #expect(store.publicKey(for: secondID) == Data([0x01]))
    #expect(store.list().map(\.deviceID) == [secondID, firstID])

    #expect(store.revoke(deviceID: firstID))
    #expect(!store.revoke(deviceID: firstID))
    #expect(store.publicKey(for: firstID) == nil)
    #expect(store.list().map(\.deviceID) == [secondID])

    store.removeAll()
    #expect(store.list().isEmpty)
}

@Test func pendingPairingRequestStorePersistsListsAndRemovesRequests() {
    let defaults = isolatedDefaults()
    let store = PendingPairingRequestStore(defaults: defaults)
    let older = identity(
        id: "00000000-0000-0000-0000-000000000002",
        name: "Older iPad",
        publicKey: [0x02],
        createdAt: 100
    )
    let newer = identity(
        id: "00000000-0000-0000-0000-000000000001",
        name: "Newer iPad",
        publicKey: [0x01],
        createdAt: 200
    )

    store.save(newer)
    store.save(older)

    #expect(store.identity(for: older.deviceID) == older)
    #expect(store.identity(for: newer.deviceID) == newer)
    #expect(store.list() == [older, newer])

    #expect(store.remove(deviceID: older.deviceID))
    #expect(!store.remove(deviceID: older.deviceID))
    #expect(store.identity(for: older.deviceID) == nil)
    #expect(store.list() == [newer])
}

@Test func pendingPairingRequestStoreOverwritesExistingRequest() {
    let defaults = isolatedDefaults()
    let store = PendingPairingRequestStore(defaults: defaults)
    let deviceID = "00000000-0000-0000-0000-000000000001"
    let original = identity(id: deviceID, name: "Original", publicKey: [0x01], createdAt: 100)
    let updated = identity(id: deviceID, name: "Updated", publicKey: [0x02], createdAt: 200)

    store.save(original)
    store.save(updated)

    #expect(store.identity(for: updated.deviceID) == updated)
    #expect(store.list() == [updated])
}

private func isolatedDefaults() -> UserDefaults {
    let suiteName = "com.remotepad.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

private func identity(
    id: String,
    name: String,
    publicKey: [UInt8],
    createdAt: TimeInterval
) -> DeviceIdentity {
    DeviceIdentity(
        deviceID: UUID(uuidString: id)!,
        deviceName: name,
        deviceType: .ipad,
        publicKey: Data(publicKey),
        createdAt: Date(timeIntervalSince1970: createdAt)
    )
}
