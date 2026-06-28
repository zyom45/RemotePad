import Foundation
import UIKit

@MainActor
final class RemotePadModel: ObservableObject {
    let identity = AppIdentity.loadOrCreate()

    @Published var agentHost = "127.0.0.1"
    @Published var agentPort = "53241"
    @Published var localPort = "19090"
    @Published var targetPort = "18080"
    @Published var browserPath = "/"
    @Published var status = "Stopped"
    @Published var pairingStatus = "Not paired"
    @Published var isProxyRunning = false

    private var proxy: LocalBrowserProxy?

    var browserURL: URL? {
        guard let port = UInt16(localPort) else { return nil }
        let path = browserPath.hasPrefix("/") ? browserPath : "/" + browserPath
        return URL(string: "http://127.0.0.1:\(port)\(path)")
    }

    func startProxy() {
        guard let agentPort = UInt16(agentPort),
              let localPort = UInt16(localPort),
              let targetPort = UInt16(targetPort) else {
            status = "Invalid port"
            return
        }

        do {
            let proxy = try LocalBrowserProxy(
                agentHost: agentHost,
                agentPort: agentPort,
                listenPort: localPort,
                targetPort: targetPort,
                identity: identity
            ) { [weak self] message in
                Task { @MainActor in
                    self?.status = message
                }
            }
            self.proxy = proxy
            proxy.start()
            isProxyRunning = true
            status = "Listening on 127.0.0.1:\(localPort)"
        } catch {
            status = "Start failed: \(error)"
        }
    }

    func stopProxy() {
        proxy?.stop()
        proxy = nil
        isProxyRunning = false
        status = "Stopped"
    }

    func requestPairing() {
        guard let agentPort = UInt16(agentPort) else {
            pairingStatus = "Invalid agent port"
            return
        }

        pairingStatus = "Requesting..."
        let client = PairingClient(
            agentHost: agentHost,
            agentPort: agentPort,
            identity: identity,
            deviceName: UIDevice.current.name
        )
        Task {
            do {
                let result = try await client.run()
                pairingStatus = "\(result.status): \(result.deviceID.uuidString)"
            } catch {
                pairingStatus = "Failed: \(error)"
            }
        }
    }
}
