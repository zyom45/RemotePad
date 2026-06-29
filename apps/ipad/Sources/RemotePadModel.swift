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
    @Published var terminalStatus = "Disconnected"
    @Published var terminalOutput = ""
    @Published var terminalInput = ""
    @Published var isTerminalConnected = false
    @Published var terminalRenderTick = 0

    private var proxy: LocalBrowserProxy?
    private var terminalClient: TerminalClient?
    private var terminalBuffer = TerminalTextBuffer()
    private var terminalOutputChunks: [Data] = []

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

    func checkPairingStatus() {
        guard let agentPort = UInt16(agentPort) else {
            pairingStatus = "Invalid agent port"
            return
        }

        pairingStatus = "Checking..."
        let client = PairingStatusClient(
            agentHost: agentHost,
            agentPort: agentPort,
            deviceID: identity.deviceID
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

    func connectTerminal() {
        guard let agentPort = UInt16(agentPort) else {
            terminalStatus = "Invalid agent port"
            return
        }

        terminalClient?.close()
        terminalBuffer.clear()
        terminalOutput = ""
        terminalStatus = "Connecting"
        isTerminalConnected = true

        let client = TerminalClient(
            agentHost: agentHost,
            agentPort: agentPort,
            identity: identity,
            onStatus: { [weak self] status in
                Task { @MainActor in
                    self?.terminalStatus = status
                    if status.hasPrefix("Disconnected") || status.hasPrefix("Connection failed") || status.hasPrefix("Auth rejected") || status.hasPrefix("Terminal closed") {
                        self?.isTerminalConnected = false
                    }
                }
            },
            onOutput: { [weak self] output in
                Task { @MainActor in
                    self?.appendTerminalOutput(output)
                }
            }
        )
        terminalClient = client
        client.connect()
    }

    func disconnectTerminal() {
        terminalClient?.close()
        terminalClient = nil
        isTerminalConnected = false
        terminalStatus = "Disconnected"
    }

    func sendTerminalInput() {
        let input = terminalInput
        guard !input.isEmpty else { return }
        terminalInput = ""
        terminalClient?.sendInput(input + "\n")
    }

    func sendTerminalData(_ data: Data) {
        terminalClient?.sendData(data)
    }

    func resizeTerminal(cols: Int, rows: Int) {
        terminalClient?.resize(cols: cols, rows: rows)
    }

    func sendTerminalInterrupt() {
        terminalClient?.sendInput("\u{03}")
    }

    func sendTerminalEscape() {
        terminalClient?.sendInput("\u{1B}")
    }

    func sendTerminalTab() {
        terminalClient?.sendInput("\t")
    }

    func clearTerminalOutput() {
        terminalBuffer.clear()
        terminalOutputChunks = [Data("\u{1B}c".utf8)]
        terminalRenderTick += 1
        terminalOutput = ""
    }

    func drainTerminalOutputChunks() -> [Data] {
        let chunks = terminalOutputChunks
        terminalOutputChunks.removeAll()
        return chunks
    }

    private func appendTerminalOutput(_ output: Data) {
        terminalOutputChunks.append(output)
        terminalRenderTick += 1
        terminalBuffer.append(String(decoding: output, as: UTF8.self))
        terminalOutput = terminalBuffer.text
    }
}
