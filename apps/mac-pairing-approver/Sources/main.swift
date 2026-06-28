import CryptoKit
import RemotePadAgentSupport
import RemotePadProtocol
import SwiftUI

@main
struct RemotePadPairingApproverApp: App {
    @StateObject private var model = PairingApprovalModel()

    var body: some Scene {
        WindowGroup("RemotePad Pairing") {
            PairingApprovalView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 480)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Pairing") {
                Button("Refresh") {
                    model.refresh()
                }
                .keyboardShortcut("r")
            }
        }
    }
}

@MainActor
final class PairingApprovalModel: ObservableObject {
    @Published private(set) var pending: [DeviceIdentity] = []
    @Published private(set) var trusted: [TrustedDeviceStore.Entry] = []
    @Published var status = "Ready"

    private let pendingStore = PendingPairingRequestStore()
    private let trustedStore = TrustedDeviceStore()

    init() {
        refresh()
    }

    func refresh() {
        pending = pendingStore.list()
        trusted = trustedStore.list()
    }

    func approve(_ identity: DeviceIdentity) {
        trustedStore.trust(publicKey: identity.publicKey, for: identity.deviceID)
        pendingStore.remove(deviceID: identity.deviceID)
        status = "Approved \(identity.deviceName)"
        refresh()
    }

    func reject(_ identity: DeviceIdentity) {
        pendingStore.remove(deviceID: identity.deviceID)
        status = "Rejected \(identity.deviceName)"
        refresh()
    }

    func revoke(_ entry: TrustedDeviceStore.Entry) {
        trustedStore.revoke(deviceID: entry.deviceID)
        status = "Revoked \(entry.deviceID.uuidString)"
        refresh()
    }
}

struct PairingApprovalView: View {
    @EnvironmentObject private var model: PairingApprovalModel

    var body: some View {
        NavigationSplitView {
            List {
                Section("Pending") {
                    ForEach(model.pending, id: \.deviceID) { identity in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(identity.deviceName)
                                .font(.headline)
                            Text(identity.deviceID.uuidString)
                                .font(.caption)
                                .textSelection(.enabled)
                        }
                    }
                }
                Section("Trusted") {
                    ForEach(model.trusted, id: \.deviceID) { entry in
                        Text(entry.deviceID.uuidString)
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Pairing")
            .toolbar {
                Button("Refresh") {
                    model.refresh()
                }
            }
        } detail: {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Pending Requests")
                        .font(.title2)
                    Spacer()
                    Text(model.status)
                        .foregroundStyle(.secondary)
                }

                if model.pending.isEmpty {
                    ContentUnavailableView("No Pending Requests", systemImage: "person.badge.plus")
                } else {
                    List {
                        ForEach(model.pending, id: \.deviceID) { identity in
                            PendingPairingRow(identity: identity)
                        }
                    }
                }

                Divider()

                Text("Trusted Devices")
                    .font(.title2)

                if model.trusted.isEmpty {
                    ContentUnavailableView("No Trusted Devices", systemImage: "checkmark.shield")
                } else {
                    List {
                        ForEach(model.trusted, id: \.deviceID) { entry in
                            TrustedDeviceRow(entry: entry)
                        }
                    }
                    .frame(minHeight: 140)
                }
            }
            .padding(24)
        }
    }
}

struct PendingPairingRow: View {
    @EnvironmentObject private var model: PairingApprovalModel
    let identity: DeviceIdentity

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(identity.deviceName)
                        .font(.headline)
                    Text(identity.deviceType.rawValue)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reject") {
                    model.reject(identity)
                }
                Button("Approve") {
                    model.approve(identity)
                }
                .buttonStyle(.borderedProminent)
            }
            DetailLine(label: "Device ID", value: identity.deviceID.uuidString)
            DetailLine(label: "Fingerprint", value: fingerprint(identity.publicKey))
            DetailLine(label: "Public Key", value: identity.publicKey.base64EncodedString())
        }
        .padding(.vertical, 8)
    }
}

struct TrustedDeviceRow: View {
    @EnvironmentObject private var model: PairingApprovalModel
    let entry: TrustedDeviceStore.Entry

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                DetailLine(label: "Device ID", value: entry.deviceID.uuidString)
                DetailLine(label: "Fingerprint", value: fingerprint(entry.publicKey))
            }
            Spacer()
            Button("Revoke") {
                model.revoke(entry)
            }
        }
        .padding(.vertical, 6)
    }
}

struct DetailLine: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}

private func fingerprint(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
