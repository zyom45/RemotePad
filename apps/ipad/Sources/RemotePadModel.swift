import Foundation
import RemotePadProtocol
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
    @Published var terminalSessions: [TerminalListItem] = []
    @Published var activeTerminalID: UUID?

    private var proxy: LocalBrowserProxy?
    private var terminalClient: TerminalClient?
    private var terminalBuffer = TerminalTextBuffer()
    private var terminalOutputChunks: [Data] = []
    private var shouldMaintainTerminalConnection = false
    private var terminalConnectionGeneration = UUID()
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?

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

    func startProxyIfNeeded() {
        if !isProxyRunning {
            startProxy()
        }
    }

    func stopProxy() {
        proxy?.stop()
        proxy = nil
        isProxyRunning = false
        status = "Stopped"
    }

    func setBrowserTarget(port: UInt16, path: String = "/") {
        targetPort = "\(port)"
        browserPath = path
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
                if let macDeviceID = result.macDeviceID, let macPublicKey = result.macPublicKey {
                    try identity.pinMac(deviceID: macDeviceID, publicKey: macPublicKey)
                }
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
        shouldMaintainTerminalConnection = true
        reconnectAttempt = 0
        startTerminalClient(mode: .resumeOrCreate, clearOutput: true)
    }

    func createTerminalSession() {
        shouldMaintainTerminalConnection = true
        reconnectAttempt = 0
        activeTerminalID = nil
        startTerminalClient(mode: .create, clearOutput: true)
    }

    func attachTerminalSession(_ terminal: TerminalListItem) {
        shouldMaintainTerminalConnection = true
        reconnectAttempt = 0
        activeTerminalID = terminal.terminalID
        startTerminalClient(mode: .attach(terminal.terminalID), clearOutput: true)
    }

    func refreshTerminalSessions() {
        terminalClient?.refreshSessions()
    }

    func disconnectTerminal() {
        shouldMaintainTerminalConnection = false
        reconnectTask?.cancel()
        reconnectTask = nil
        terminalConnectionGeneration = UUID()
        terminalClient?.disconnect()
        terminalClient = nil
        isTerminalConnected = false
        terminalStatus = "Disconnected (session kept on Mac)"
    }

    func terminateTerminalSession() {
        shouldMaintainTerminalConnection = false
        reconnectTask?.cancel()
        reconnectTask = nil
        terminalConnectionGeneration = UUID()
        terminalClient?.terminate()
        terminalClient = nil
        if let activeTerminalID {
            terminalSessions.removeAll { $0.terminalID == activeTerminalID }
        }
        activeTerminalID = nil
        isTerminalConnected = false
        terminalStatus = "Session ended"
    }

    private func startTerminalClient(mode: TerminalStartupMode, clearOutput: Bool) {
        guard let agentPort = UInt16(agentPort) else {
            terminalStatus = "Invalid agent port"
            return
        }

        reconnectTask?.cancel()
        reconnectTask = nil
        terminalClient?.disconnect()
        if clearOutput {
            clearTerminalForConnection()
        }
        terminalStatus = "Connecting"
        isTerminalConnected = false
        let generation = UUID()
        terminalConnectionGeneration = generation

        let client = TerminalClient(
            agentHost: agentHost,
            agentPort: agentPort,
            identity: identity,
            startupMode: mode,
            onStatus: { [weak self] status in
                Task { @MainActor in
                    guard let self, self.terminalConnectionGeneration == generation else { return }
                    self.terminalStatus = status
                }
            },
            onOutput: { [weak self] output in
                Task { @MainActor in
                    guard let self, self.terminalConnectionGeneration == generation else { return }
                    self.appendTerminalOutput(output)
                }
            },
            onSessions: { [weak self] sessions in
                Task { @MainActor in
                    guard let self, self.terminalConnectionGeneration == generation else { return }
                    self.terminalSessions = sessions.sorted { $0.lastActiveAt > $1.lastActiveAt }
                }
            },
            onActiveTerminal: { [weak self] terminalID in
                Task { @MainActor in
                    guard let self, self.terminalConnectionGeneration == generation else { return }
                    self.activeTerminalID = terminalID
                    self.isTerminalConnected = true
                    self.reconnectAttempt = 0
                }
            },
            onDisconnected: { [weak self] in
                Task { @MainActor in
                    guard let self, self.terminalConnectionGeneration == generation else { return }
                    self.isTerminalConnected = false
                    self.terminalClient = nil
                    self.scheduleTerminalReconnect()
                }
            }
        )
        terminalClient = client
        client.connect()
    }

    private func scheduleTerminalReconnect() {
        guard shouldMaintainTerminalConnection else { return }
        reconnectAttempt += 1
        let delay = min(10, 1 << min(reconnectAttempt - 1, 3))
        terminalStatus = "Reconnecting in \(delay)s"
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.shouldMaintainTerminalConnection else { return }
                let mode = self.activeTerminalID.map(TerminalStartupMode.attach) ?? .resumeOrCreate
                self.startTerminalClient(mode: mode, clearOutput: false)
            }
        }
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

    private func clearTerminalForConnection() {
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
