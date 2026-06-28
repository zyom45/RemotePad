import Foundation
import Darwin
import CryptoKit
import Network
import RemotePadProtocol

@main
struct RemotePadAgentCommand {
    @MainActor
    static func main() async throws {
        if handleUtilityCommand(arguments: CommandLine.arguments) {
            return
        }

        let configuration = AgentConfiguration.default
        let agent = RemotePadAgent(configuration: configuration)
        let signalSources = installSignalHandlers {
            Task { @MainActor in
                agent.stop()
                Foundation.exit(0)
            }
        }
        try agent.start()

        print("RemotePad Agent")
        print("  service: \(configuration.serviceType)")
        print("  network: \(configuration.networkExposure.description)")
        print("  discovery: \(configuration.publishesBonjour ? "bonjour" : "disabled")")
        print("  port: \(agent.port)")
        print("  device: \(configuration.deviceName)")
        print("  press Ctrl-C to stop")

        await waitForever()
        _ = signalSources
    }

    private static func handleUtilityCommand(arguments: [String]) -> Bool {
        guard arguments.count >= 2 else { return false }

        let store = TrustedDeviceStore()
        let pendingStore = PendingPairingRequestStore()
        switch arguments[1] {
        case "--trust-device":
            guard arguments.count == 4,
                  let deviceID = UUID(uuidString: arguments[2]),
                  let publicKey = Data(base64Encoded: arguments[3]),
                  isValidSigningPublicKey(publicKey) else {
                print("usage: swift run remotepad-agent --trust-device <device-id> <public-key-base64>")
                return true
            }

            store.trust(publicKey: publicKey, for: deviceID)
            print("trusted device: \(deviceID)")
            print("fingerprint: \(fingerprint(publicKey))")
            return true

        case "--list-trusted":
            let devices = store.list()
            if devices.isEmpty {
                print("no trusted devices")
            } else {
                for device in devices {
                    print("\(device.deviceID.uuidString) \(device.publicKey.base64EncodedString()) \(fingerprint(device.publicKey))")
                }
            }
            return true

        case "--list-pairing-requests":
            let requests = pendingStore.list()
            if requests.isEmpty {
                print("no pending pairing requests")
            } else {
                for request in requests {
                    print("\(request.deviceID.uuidString) \(request.deviceName) \(request.deviceType.rawValue) \(request.publicKey.base64EncodedString()) \(fingerprint(request.publicKey))")
                }
            }
            return true

        case "--approve-pairing":
            guard arguments.count == 3, let deviceID = UUID(uuidString: arguments[2]) else {
                print("usage: swift run remotepad-agent --approve-pairing <device-id>")
                return true
            }
            guard let identity = pendingStore.identity(for: deviceID) else {
                print("no pending pairing request: \(deviceID)")
                return true
            }

            store.trust(publicKey: identity.publicKey, for: identity.deviceID)
            pendingStore.remove(deviceID: identity.deviceID)
            print("approved pairing: \(identity.deviceID)")
            print("device: \(identity.deviceName)")
            print("fingerprint: \(fingerprint(identity.publicKey))")
            return true

        case "--reject-pairing":
            guard arguments.count == 3, let deviceID = UUID(uuidString: arguments[2]) else {
                print("usage: swift run remotepad-agent --reject-pairing <device-id>")
                return true
            }
            if pendingStore.remove(deviceID: deviceID) {
                print("rejected pairing: \(deviceID)")
            } else {
                print("no pending pairing request: \(deviceID)")
            }
            return true

        case "--revoke-device":
            guard arguments.count == 3, let deviceID = UUID(uuidString: arguments[2]) else {
                print("usage: swift run remotepad-agent --revoke-device <device-id>")
                return true
            }

            if store.revoke(deviceID: deviceID) {
                print("revoked device: \(deviceID)")
            } else {
                print("device not trusted: \(deviceID)")
            }
            return true

        case "--clear-trusted-devices":
            store.removeAll()
            print("cleared trusted devices")
            return true

        case "--help":
            printUsage()
            return true

        default:
            return false
        }
    }

    private static func printUsage() {
        print("""
        usage:
          swift run remotepad-agent
          swift run remotepad-agent --trust-device <device-id> <public-key-base64>
          swift run remotepad-agent --list-trusted
          swift run remotepad-agent --list-pairing-requests
          swift run remotepad-agent --approve-pairing <device-id>
          swift run remotepad-agent --reject-pairing <device-id>
          swift run remotepad-agent --revoke-device <device-id>
          swift run remotepad-agent --clear-trusted-devices
        """)
    }

    private static func isValidSigningPublicKey(_ data: Data) -> Bool {
        (try? Curve25519.Signing.PublicKey(rawRepresentation: data)) != nil
    }

    private static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func waitForever() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
        }
    }

    private static func installSignalHandlers(_ handler: @escaping () -> Void) -> [DispatchSourceSignal] {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        let signals = [SIGINT, SIGTERM]
        return signals.map { signalNumber in
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler(handler: handler)
            source.resume()
            return source
        }
    }
}

struct AgentConfiguration {
    var deviceID: UUID
    var deviceName: String
    var serviceType: String
    var capabilities: CapabilitySet
    var permissions: Permissions
    var networkExposure: NetworkExposure
    var publishesBonjour: Bool
    var allowsDevelopmentTrustOnFirstUse: Bool

    static var `default`: AgentConfiguration {
        AgentConfiguration(
            deviceID: persistedOrGeneratedDeviceID(),
            deviceName: Host.current().localizedName ?? "RemotePad Mac",
            serviceType: "_remotepad._tcp",
            capabilities: .mvp,
            permissions: .mvpDefault,
            networkExposure: .loopbackOnly,
            publishesBonjour: false,
            allowsDevelopmentTrustOnFirstUse: false
        )
    }

    private static func persistedOrGeneratedDeviceID() -> UUID {
        // Temporary development identity. The production agent will store this in Keychain.
        let defaults = UserDefaults.standard
        let key = "RemotePadAgentDeviceID"
        if let value = defaults.string(forKey: key), let uuid = UUID(uuidString: value) {
            return uuid
        }

        let uuid = UUID()
        defaults.set(uuid.uuidString, forKey: key)
        return uuid
    }
}

enum NetworkExposure: Sendable {
    case loopbackOnly
    case localNetwork

    var description: String {
        switch self {
        case .loopbackOnly:
            return "loopback-only"
        case .localNetwork:
            return "local-network"
        }
    }
}

@MainActor
final class RemotePadAgent {
    private let configuration: AgentConfiguration
    private var listener: NWListener?
    private var connections: [UUID: AgentConnection] = [:]
    private let terminalStore = TerminalStore()
    private let trustedDeviceStore = TrustedDeviceStore()
    private let pendingPairingStore = PendingPairingRequestStore()
    private(set) var port: UInt16 = 0

    init(configuration: AgentConfiguration) {
        self.configuration = configuration
    }

    func start() throws {
        let parameters = NWParameters.tcp
        if configuration.networkExposure == .loopbackOnly {
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        }

        let listener = try NWListener(using: parameters, on: .any)
        if configuration.publishesBonjour {
            listener.service = NWListener.Service(
                name: configuration.deviceName,
                type: configuration.serviceType,
                txtRecord: serviceTXTRecord
            )
        }
        listener.newConnectionHandler = { connection in
            Task { @MainActor in
                self.accept(connection)
            }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleState(state)
            }
        }

        self.listener = listener
        listener.start(queue: .main)
    }

    func stop() {
        for connection in connections.values {
            connection.stop()
        }
        connections.removeAll()
        terminalStore.closeAll()
        listener?.cancel()
        listener = nil
    }

    private func accept(_ nwConnection: NWConnection) {
        let connection = AgentConnection(
            nwConnection: nwConnection,
            configuration: configuration,
            terminalStore: terminalStore,
            trustedDeviceStore: trustedDeviceStore,
            pendingPairingStore: pendingPairingStore,
            onClose: { [weak self] id in
                self?.connections[id] = nil
            }
        )
        connections[connection.id] = connection
        connection.start()
    }

    private var serviceTXTRecord: NWTXTRecord {
        var record = NWTXTRecord()
        record["version"] = "\(RemotePadProtocol.currentVersion)"
        record["device_id"] = configuration.deviceID.uuidString
        record["host_name"] = configuration.deviceName
        record["capabilities"] = configuration.capabilities.channels.map(\.rawValue).joined(separator: ",")
        record["pairing"] = "available"
        return record
    }

    private func handleState(_ state: NWListener.State) {
        switch state {
        case .ready:
            if let port = listener?.port?.rawValue {
                self.port = port
                print("agent ready on port \(port)")
            } else {
                print("agent ready")
            }
        case .failed(let error):
            print("agent failed: \(error)")
            listener?.cancel()
        case .cancelled:
            print("agent stopped")
        default:
            break
        }
    }
}

@MainActor
final class AgentConnection {
    let id = UUID()

    private let nwConnection: NWConnection
    private let configuration: AgentConfiguration
    private let terminalStore: TerminalStore
    private let trustedDeviceStore: TrustedDeviceStore
    private let pendingPairingStore: PendingPairingRequestStore
    private let decoder = FrameStreamDecoder()
    private let onClose: (UUID) -> Void
    private var pendingPairingIdentity: DeviceIdentity?
    private var pendingPairingChallenge: Data?
    private var clientDeviceID: UUID?
    private var clientNonce: Data?
    private var serverNonce: Data?
    private var offeredClientPublicKey: Data?
    private var sessionID: UUID?
    private var isAuthenticated = false
    private var browserStreams: [UUID: BrowserTCPStream] = [:]

    init(
        nwConnection: NWConnection,
        configuration: AgentConfiguration,
        terminalStore: TerminalStore,
        trustedDeviceStore: TrustedDeviceStore,
        pendingPairingStore: PendingPairingRequestStore,
        onClose: @escaping (UUID) -> Void
    ) {
        self.nwConnection = nwConnection
        self.configuration = configuration
        self.terminalStore = terminalStore
        self.trustedDeviceStore = trustedDeviceStore
        self.pendingPairingStore = pendingPairingStore
        self.onClose = onClose
    }

    func start() {
        print("incoming connection \(id) from \(nwConnection.endpoint)")
        nwConnection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleState(state)
            }
        }
        receiveNext()
        nwConnection.start(queue: .main)
    }

    func stop() {
        close()
    }

    private func receiveNext() {
        nwConnection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                self?.handleReceive(data: data, isComplete: isComplete, error: error)
            }
        }
    }

    private func handleReceive(data: Data?, isComplete: Bool, error: NWError?) {
        if let error {
            print("connection \(id) receive failed: \(error)")
            close()
            return
        }

        if let data, !data.isEmpty {
            do {
                let frames = try decoder.append(data)
                for frame in frames {
                    try handleFrame(frame)
                }
            } catch {
                print("connection \(id) protocol error: \(error)")
                sendProtocolError(code: "protocol_error", message: "\(error)", requestID: nil)
                close()
                return
            }
        }

        if isComplete {
            close()
        } else {
            receiveNext()
        }
    }

    private func handleFrame(_ frame: Frame) throws {
        let header = try FrameCodec.decodeHeader(MessageHeader.self, from: frame)
        switch header.kind {
        case "pairing.start":
            let message = try FrameCodec.decodeHeader(PairingStart.self, from: frame)
            handlePairingStart(message, requestID: frame.requestID)
        case "pairing.response":
            let message = try FrameCodec.decodeHeader(PairingResponse.self, from: frame)
            handlePairingResponse(message, requestID: frame.requestID)
        case "pairing.status":
            let message = try FrameCodec.decodeHeader(PairingStatusRequest.self, from: frame)
            handlePairingStatus(message, requestID: frame.requestID)
        case "client.hello":
            let message = try FrameCodec.decodeHeader(ClientHello.self, from: frame)
            handleClientHello(message, requestID: frame.requestID)
        case "auth.proof":
            let message = try FrameCodec.decodeHeader(AuthProof.self, from: frame)
            handleAuthProof(message, requestID: frame.requestID)
        case "terminal.create":
            let message = try FrameCodec.decodeHeader(TerminalCreate.self, from: frame)
            handleTerminalCreate(message, channelID: frame.channelID, requestID: frame.requestID)
        case "terminal.input":
            let message = try FrameCodec.decodeHeader(TerminalInput.self, from: frame)
            handleTerminalInput(message, payload: frame.payload, requestID: frame.requestID)
        case "terminal.resize":
            let message = try FrameCodec.decodeHeader(TerminalResize.self, from: frame)
            handleTerminalResize(message, requestID: frame.requestID)
        case "terminal.list":
            handleTerminalList(channelID: frame.channelID, requestID: frame.requestID)
        case "terminal.attach":
            let message = try FrameCodec.decodeHeader(TerminalAttach.self, from: frame)
            handleTerminalAttach(message, channelID: frame.channelID, requestID: frame.requestID)
        case "terminal.close":
            let message = try FrameCodec.decodeHeader(TerminalClose.self, from: frame)
            handleTerminalClose(message, channelID: frame.channelID, requestID: frame.requestID)
        case "browser.request":
            let message = try FrameCodec.decodeHeader(BrowserRequest.self, from: frame)
            handleBrowserRequest(message, channelID: frame.channelID, requestID: frame.requestID, payload: frame.payload)
        case "browser.stream.open":
            let message = try FrameCodec.decodeHeader(BrowserStreamOpen.self, from: frame)
            handleBrowserStreamOpen(message, channelID: frame.channelID, requestID: frame.requestID)
        case "browser.stream.data":
            let message = try FrameCodec.decodeHeader(BrowserStreamData.self, from: frame)
            handleBrowserStreamData(message, payload: frame.payload, requestID: frame.requestID)
        case "browser.stream.close":
            let message = try FrameCodec.decodeHeader(BrowserStreamClose.self, from: frame)
            handleBrowserStreamClose(message)
        case "ping":
            sendPong(requestID: frame.requestID)
        default:
            sendProtocolError(
                code: "unsupported_message",
                message: "Unsupported message kind: \(header.kind)",
                requestID: frame.requestID
            )
        }
    }

    private func handlePairingStart(_ message: PairingStart, requestID: UInt32) {
        guard message.identity.deviceType == .ipad else {
            sendPairingResult(
                accepted: false,
                status: "rejected",
                deviceID: message.identity.deviceID,
                reason: "unsupported_device_type",
                requestID: requestID
            )
            return
        }
        guard verifyPublicKey(message.identity.publicKey) else {
            sendPairingResult(
                accepted: false,
                status: "rejected",
                deviceID: message.identity.deviceID,
                reason: "invalid_public_key",
                requestID: requestID
            )
            return
        }

        let challenge = Data.randomBytes(count: 32)
        pendingPairingIdentity = message.identity
        pendingPairingChallenge = challenge
        let response = PairingChallenge(
            challenge: challenge,
            macIdentity: DeviceIdentity(
                deviceID: configuration.deviceID,
                deviceName: configuration.deviceName,
                deviceType: .mac,
                publicKey: Data(),
                createdAt: Date()
            )
        )
        sendHeader(response, type: .response, channelID: 1, requestID: requestID)
    }

    private func handlePairingResponse(_ message: PairingResponse, requestID: UInt32) {
        guard let identity = pendingPairingIdentity, let challenge = pendingPairingChallenge else {
            sendPairingResult(
                accepted: false,
                status: "rejected",
                deviceID: UUID(),
                reason: "pairing_start_required",
                requestID: requestID
            )
            return
        }

        let transcript = PairingTranscript.make(
            challenge: challenge,
            ipadIdentity: identity,
            macDeviceID: configuration.deviceID
        )
        guard verify(signature: message.signature, for: transcript, publicKey: identity.publicKey) else {
            sendPairingResult(
                accepted: false,
                status: "rejected",
                deviceID: identity.deviceID,
                reason: "invalid_signature",
                requestID: requestID
            )
            return
        }

        pendingPairingStore.save(identity)
        sendPairingResult(
            accepted: true,
            status: "pending_approval",
            deviceID: identity.deviceID,
            requestID: requestID
        )
        print("pending pairing request \(identity.deviceID) \(identity.deviceName)")
    }

    private func handlePairingStatus(_ message: PairingStatusRequest, requestID: UInt32) {
        if trustedDeviceStore.publicKey(for: message.deviceID) != nil {
            sendPairingResult(
                accepted: true,
                status: "approved",
                deviceID: message.deviceID,
                requestID: requestID
            )
        } else if pendingPairingStore.identity(for: message.deviceID) != nil {
            sendPairingResult(
                accepted: true,
                status: "pending_approval",
                deviceID: message.deviceID,
                requestID: requestID
            )
        } else {
            sendPairingResult(
                accepted: false,
                status: "not_found",
                deviceID: message.deviceID,
                reason: "pairing_request_not_found",
                requestID: requestID
            )
        }
    }

    private func sendPairingResult(
        accepted: Bool,
        status: String,
        deviceID: UUID,
        reason: String? = nil,
        requestID: UInt32
    ) {
        let result = PairingResult(
            accepted: accepted,
            status: status,
            deviceID: deviceID,
            permissions: accepted ? configuration.permissions : nil,
            reason: reason
        )
        sendHeader(result, type: .response, flags: accepted ? [] : [.error], channelID: 1, requestID: requestID)
    }

    private func verifyPublicKey(_ publicKey: Data) -> Bool {
        (try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey)) != nil
    }

    private func handleBrowserStreamOpen(
        _ message: BrowserStreamOpen,
        channelID: UInt32,
        requestID: UInt32
    ) {
        guard isAuthenticated else {
            sendProtocolError(code: "auth_required", message: "Browser stream requires authentication.", requestID: requestID)
            return
        }
        guard configuration.permissions.browserProxy else {
            sendProtocolError(code: "permission_denied", message: "Browser proxy permission is not granted.", requestID: requestID)
            return
        }
        guard browserStreams[message.streamID] == nil else {
            sendProtocolError(code: "browser_stream_exists", message: "Browser stream already exists.", requestID: requestID)
            return
        }

        let stream = BrowserTCPStream(
            streamID: message.streamID,
            target: message.target,
            onData: { [weak self] streamID, data in
                self?.sendBrowserStreamData(streamID: streamID, data: data, channelID: channelID)
            },
            onClose: { [weak self] streamID, reason in
                self?.browserStreams[streamID] = nil
                self?.sendBrowserStreamClose(streamID: streamID, reason: reason, channelID: channelID)
            }
        )
        browserStreams[message.streamID] = stream
        stream.start()
    }

    private func handleBrowserStreamData(
        _ message: BrowserStreamData,
        payload: Data,
        requestID: UInt32
    ) {
        guard isAuthenticated else {
            sendProtocolError(code: "auth_required", message: "Browser stream requires authentication.", requestID: requestID)
            return
        }
        guard let stream = browserStreams[message.streamID] else {
            sendProtocolError(code: "browser_stream_not_found", message: "Browser stream not found.", requestID: requestID)
            return
        }
        stream.send(payload)
    }

    private func handleBrowserStreamClose(_ message: BrowserStreamClose) {
        browserStreams[message.streamID]?.close(reason: message.reason ?? "client_closed")
        browserStreams[message.streamID] = nil
    }

    private func sendBrowserStreamData(streamID: UUID, data: Data, channelID: UInt32) {
        let message = BrowserStreamData(streamID: streamID)
        sendHeader(message, type: .data, channelID: channelID, requestID: 0, payload: data)
    }

    private func sendBrowserStreamClose(streamID: UUID, reason: String, channelID: UInt32) {
        let message = BrowserStreamClose(streamID: streamID, reason: reason)
        sendHeader(message, type: .response, channelID: channelID, requestID: 0)
    }

    private func handleClientHello(_ message: ClientHello, requestID: UInt32) {
        guard message.supportedProtocols.contains(RemotePadProtocol.currentVersion) else {
            sendProtocolVersionUnsupported(requestID: requestID)
            return
        }

        clientDeviceID = message.deviceID
        clientNonce = message.nonce
        offeredClientPublicKey = message.publicKey
        let nonce = Data.randomBytes(count: 32)
        serverNonce = nonce
        let response = ServerHello(
            deviceID: configuration.deviceID,
            nonce: nonce,
            capabilities: configuration.capabilities
        )
        sendHeader(response, type: .response, channelID: 1, requestID: requestID)
    }

    private func handleAuthProof(_ message: AuthProof, requestID: UInt32) {
        guard let clientDeviceID, let clientNonce, let serverNonce else {
            sendAuthRejected(reason: "hello_required", requestID: requestID)
            return
        }

        guard let publicKey = trustedPublicKey(for: clientDeviceID) else {
            sendAuthRejected(reason: "device_not_trusted", requestID: requestID)
            return
        }

        let transcript = AuthTranscript.make(
            clientDeviceID: clientDeviceID,
            clientNonce: clientNonce,
            serverDeviceID: configuration.deviceID,
            serverNonce: serverNonce
        )
        guard verify(signature: message.signature, for: transcript, publicKey: publicKey) else {
            sendAuthRejected(reason: "invalid_signature", requestID: requestID)
            return
        }

        let sessionID = UUID()
        self.sessionID = sessionID
        isAuthenticated = true

        let result = AuthResult(
            accepted: true,
            sessionID: sessionID,
            permissions: configuration.permissions
        )
        sendHeader(result, type: .response, channelID: 1, requestID: requestID)
    }

    private func trustedPublicKey(for deviceID: UUID) -> Data? {
        if let publicKey = trustedDeviceStore.publicKey(for: deviceID) {
            return publicKey
        }

        guard configuration.allowsDevelopmentTrustOnFirstUse, let publicKey = offeredClientPublicKey else {
            return nil
        }

        trustedDeviceStore.trust(publicKey: publicKey, for: deviceID)
        print("trusted development client \(deviceID)")
        return publicKey
    }

    private func verify(signature: Data, for transcript: Data, publicKey: Data) -> Bool {
        do {
            let signingKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
            return signingKey.isValidSignature(signature, for: transcript)
        } catch {
            return false
        }
    }

    private func sendAuthRejected(reason: String, requestID: UInt32) {
        let result = AuthResult(
            accepted: false,
            sessionID: nil,
            permissions: nil,
            reason: reason
        )
        sendHeader(result, type: .response, flags: [.error], channelID: 1, requestID: requestID)
    }

    private func handleTerminalCreate(_ message: TerminalCreate, channelID: UInt32, requestID: UInt32) {
        guard isAuthenticated else {
            sendProtocolError(code: "auth_required", message: "Terminal requires authentication.", requestID: requestID)
            return
        }
        guard configuration.permissions.terminal else {
            sendProtocolError(code: "permission_denied", message: "Terminal permission is not granted.", requestID: requestID)
            return
        }

        do {
            let terminal = try terminalStore.create(message)
            terminalStore.subscribe(connectionID: id, terminalID: terminal.id) { [weak self] terminalID, data in
                self?.sendTerminalOutput(terminalID: terminalID, data: data, channelID: channelID)
            }
            terminal.start()

            let created = TerminalCreated(
                terminalID: terminal.id,
                shell: message.shell,
                cwd: message.cwd,
                cols: message.cols,
                rows: message.rows
            )
            sendHeader(created, type: .response, channelID: channelID, requestID: requestID)
        } catch {
            sendProtocolError(code: "terminal_create_failed", message: "\(error)", requestID: requestID)
        }
    }

    private func handleTerminalInput(_ message: TerminalInput, payload: Data, requestID: UInt32) {
        guard let terminal = terminalStore.terminal(id: message.terminalID) else {
            sendProtocolError(code: "terminal_not_found", message: "Terminal not found.", requestID: requestID)
            return
        }

        do {
            try terminal.write(payload)
        } catch {
            sendProtocolError(code: "terminal_write_failed", message: "\(error)", requestID: requestID)
        }
    }

    private func handleTerminalResize(_ message: TerminalResize, requestID: UInt32) {
        guard let terminal = terminalStore.terminal(id: message.terminalID) else {
            sendProtocolError(code: "terminal_not_found", message: "Terminal not found.", requestID: requestID)
            return
        }

        do {
            try terminal.resize(cols: message.cols, rows: message.rows)
        } catch {
            sendProtocolError(code: "terminal_resize_failed", message: "\(error)", requestID: requestID)
        }
    }

    private func handleTerminalList(channelID: UInt32, requestID: UInt32) {
        guard isAuthenticated else {
            sendProtocolError(code: "auth_required", message: "Terminal list requires authentication.", requestID: requestID)
            return
        }
        guard configuration.permissions.terminal else {
            sendProtocolError(code: "permission_denied", message: "Terminal permission is not granted.", requestID: requestID)
            return
        }

        let result = TerminalListResult(terminals: terminalStore.list())
        sendHeader(result, type: .response, channelID: channelID, requestID: requestID)
    }

    private func handleTerminalAttach(_ message: TerminalAttach, channelID: UInt32, requestID: UInt32) {
        guard isAuthenticated else {
            sendProtocolError(code: "auth_required", message: "Terminal attach requires authentication.", requestID: requestID)
            return
        }
        guard configuration.permissions.terminal else {
            sendProtocolError(code: "permission_denied", message: "Terminal permission is not granted.", requestID: requestID)
            return
        }
        guard let terminal = terminalStore.terminal(id: message.terminalID) else {
            sendProtocolError(code: "terminal_not_found", message: "Terminal not found.", requestID: requestID)
            return
        }

        terminalStore.subscribe(connectionID: id, terminalID: terminal.id) { [weak self] terminalID, data in
            self?.sendTerminalOutput(terminalID: terminalID, data: data, channelID: channelID)
        }

        let attached = TerminalAttached(terminal: terminal.listItem)
        sendHeader(attached, type: .response, channelID: channelID, requestID: requestID)
        let replay = terminal.outputReplay()
        if !replay.isEmpty {
            sendTerminalOutput(terminalID: terminal.id, data: replay, channelID: channelID)
        }
    }

    private func handleTerminalClose(_ message: TerminalClose, channelID: UInt32, requestID: UInt32) {
        guard isAuthenticated else {
            sendProtocolError(code: "auth_required", message: "Terminal close requires authentication.", requestID: requestID)
            return
        }
        guard configuration.permissions.terminal else {
            sendProtocolError(code: "permission_denied", message: "Terminal permission is not granted.", requestID: requestID)
            return
        }
        guard terminalStore.close(id: message.terminalID) else {
            sendProtocolError(code: "terminal_not_found", message: "Terminal not found.", requestID: requestID)
            return
        }

        let closed = TerminalClosed(terminalID: message.terminalID, reason: "client_requested")
        sendHeader(closed, type: .response, channelID: channelID, requestID: requestID)
    }

    private func handleBrowserRequest(
        _ message: BrowserRequest,
        channelID: UInt32,
        requestID: UInt32,
        payload: Data
    ) {
        guard isAuthenticated else {
            sendProtocolError(code: "auth_required", message: "Browser proxy requires authentication.", requestID: requestID)
            return
        }
        guard configuration.permissions.browserProxy else {
            sendProtocolError(code: "permission_denied", message: "Browser proxy permission is not granted.", requestID: requestID)
            return
        }

        Task { [weak self] in
            do {
                let proxied = try await BrowserHTTPProxy.perform(message, body: payload)
                await MainActor.run {
                    self?.sendHeader(
                        proxied.response,
                        type: .response,
                        channelID: channelID,
                        requestID: requestID,
                        payload: proxied.body
                    )
                }
            } catch {
                await MainActor.run {
                    self?.sendProtocolError(
                        code: "browser_target_unreachable",
                        message: "\(error)",
                        requestID: requestID
                    )
                }
            }
        }
    }

    private func sendTerminalOutput(terminalID: UUID, data: Data, channelID: UInt32) {
        let output = TerminalOutput(terminalID: terminalID)
        sendHeader(output, type: .data, channelID: channelID, requestID: 0, payload: data)
    }

    private func sendPong(requestID: UInt32) {
        let header = MessageHeader(kind: "pong")
        sendHeader(header, type: .pong, channelID: 1, requestID: requestID)
    }

    private func sendProtocolError(code: String, message: String, requestID: UInt32?) {
        let error = ProtocolErrorMessage(code: code, message: message, requestID: requestID)
        sendHeader(error, type: .error, flags: [.error], channelID: 1, requestID: requestID ?? 0)
    }

    private func sendProtocolVersionUnsupported(requestID: UInt32) {
        let error = ProtocolErrorMessage(
            code: "protocol_version_unsupported",
            message: "Client does not support protocol \(RemotePadProtocol.currentVersion).",
            requestID: requestID,
            supportedProtocols: [RemotePadProtocol.currentVersion],
            minimumSupportedProtocol: RemotePadProtocol.currentVersion
        )
        sendHeader(error, type: .error, flags: [.error], channelID: 1, requestID: requestID)
    }

    private func sendHeader<Header: Encodable>(
        _ header: Header,
        type: FrameType,
        flags: FrameFlags = [],
        channelID: UInt32,
        requestID: UInt32,
        payload: Data = Data()
    ) {
        do {
            let data = try FrameCodec.encodeHeader(
                header,
                type: type,
                flags: flags,
                channelID: channelID,
                requestID: requestID,
                payload: payload
            )
            nwConnection.send(content: data, completion: .contentProcessed { [weak self] error in
                if let error {
                    Task { @MainActor in
                        guard let self else { return }
                        print("connection \(self.id) send failed: \(error)")
                        self.close()
                    }
                }
            })
        } catch {
            print("connection \(id) encode failed: \(error)")
            close()
        }
    }

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            print("connection \(id) ready")
        case .failed(let error):
            print("connection \(id) failed: \(error)")
            close()
        case .cancelled:
            onClose(id)
        default:
            break
        }
    }

    private func close() {
        terminalStore.unsubscribeConnection(id)
        let streams = Array(browserStreams.values)
        browserStreams.removeAll()
        for stream in streams {
            stream.close(reason: "connection_closed")
        }
        nwConnection.cancel()
        onClose(id)
    }
}

@MainActor
final class BrowserTCPStream {
    let streamID: UUID

    private let connection: NWConnection
    private let onData: (UUID, Data) -> Void
    private let onClose: (UUID, String) -> Void
    private var isClosed = false

    init(
        streamID: UUID,
        target: BrowserTarget,
        onData: @escaping (UUID, Data) -> Void,
        onClose: @escaping (UUID, String) -> Void
    ) {
        self.streamID = streamID
        self.onData = onData
        self.onClose = onClose
        self.connection = NWConnection(
            host: NWEndpoint.Host(target.host),
            port: NWEndpoint.Port(rawValue: target.port)!,
            using: .tcp
        )
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleState(state)
            }
        }
        receiveNext()
        connection.start(queue: .main)
    }

    func send(_ data: Data) {
        guard !data.isEmpty, !isClosed else { return }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error {
                Task { @MainActor in
                    self?.close(reason: "send_failed:\(error)")
                }
            }
        })
    }

    func close(reason: String) {
        guard !isClosed else { return }
        isClosed = true
        connection.cancel()
        onClose(streamID, reason)
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                self?.handleReceive(data: data, isComplete: isComplete, error: error)
            }
        }
    }

    private func handleReceive(data: Data?, isComplete: Bool, error: NWError?) {
        if let error {
            close(reason: "receive_failed:\(error)")
            return
        }

        if let data, !data.isEmpty {
            onData(streamID, data)
        }

        if isComplete {
            close(reason: "eof")
        } else if !isClosed {
            receiveNext()
        }
    }

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .failed(let error):
            close(reason: "connect_failed:\(error)")
        case .cancelled:
            if !isClosed {
                close(reason: "cancelled")
            }
        default:
            break
        }
    }
}

final class TrustedDeviceStore {
    struct Entry {
        var deviceID: UUID
        var publicKey: Data
    }

    private let defaults = UserDefaults.standard
    private let key = "RemotePadTrustedDevicePublicKeys"

    func publicKey(for deviceID: UUID) -> Data? {
        allKeys()[deviceID.uuidString]
    }

    func list() -> [Entry] {
        allKeys()
            .compactMap { key, publicKey -> Entry? in
                guard let deviceID = UUID(uuidString: key) else { return nil }
                return Entry(deviceID: deviceID, publicKey: publicKey)
            }
            .sorted { $0.deviceID.uuidString < $1.deviceID.uuidString }
    }

    func trust(publicKey: Data, for deviceID: UUID) {
        var keys = allKeys()
        keys[deviceID.uuidString] = publicKey
        defaults.set(encode(keys), forKey: key)
    }

    func revoke(deviceID: UUID) -> Bool {
        var keys = allKeys()
        guard keys.removeValue(forKey: deviceID.uuidString) != nil else {
            return false
        }
        defaults.set(encode(keys), forKey: key)
        return true
    }

    func removeAll() {
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
}

final class PendingPairingRequestStore {
    private let defaults = UserDefaults.standard
    private let key = "RemotePadPendingPairingRequests"

    func identity(for deviceID: UUID) -> DeviceIdentity? {
        allRequests()[deviceID.uuidString]
    }

    func list() -> [DeviceIdentity] {
        allRequests()
            .values
            .sorted { $0.createdAt < $1.createdAt }
    }

    func save(_ identity: DeviceIdentity) {
        var requests = allRequests()
        requests[identity.deviceID.uuidString] = identity
        defaults.set(encode(requests), forKey: key)
    }

    @discardableResult
    func remove(deviceID: UUID) -> Bool {
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
}

@MainActor
final class TerminalStore {
    private var terminals: [UUID: PTYTerminalSession] = [:]
    private var subscriptions: [UUID: [UUID: (UUID, Data) -> Void]] = [:]

    func create(_ create: TerminalCreate) throws -> PTYTerminalSession {
        let terminal = try PTYTerminalSession(create: create) { [weak self] terminalID, data in
            self?.broadcast(terminalID: terminalID, data: data)
        } onExit: { [weak self] terminalID in
            self?.terminals[terminalID] = nil
            self?.subscriptions[terminalID] = nil
        }
        terminals[terminal.id] = terminal
        return terminal
    }

    func terminal(id: UUID) -> PTYTerminalSession? {
        terminals[id]
    }

    func list() -> [TerminalListItem] {
        terminals.values
            .sorted { $0.createdAt < $1.createdAt }
            .map { $0.listItem }
    }

    func subscribe(
        connectionID: UUID,
        terminalID: UUID,
        onOutput: @escaping (UUID, Data) -> Void
    ) {
        var terminalSubscriptions = subscriptions[terminalID] ?? [:]
        terminalSubscriptions[connectionID] = onOutput
        subscriptions[terminalID] = terminalSubscriptions
    }

    func unsubscribeConnection(_ connectionID: UUID) {
        for terminalID in subscriptions.keys {
            subscriptions[terminalID]?[connectionID] = nil
        }
    }

    func closeAll() {
        for terminal in terminals.values {
            terminal.close()
        }
        terminals.removeAll()
        subscriptions.removeAll()
    }

    func close(id: UUID) -> Bool {
        guard let terminal = terminals[id] else {
            return false
        }
        terminal.close()
        terminals[id] = nil
        subscriptions[id] = nil
        return true
    }

    private func broadcast(terminalID: UUID, data: Data) {
        terminal(id: terminalID)?.markActive()
        guard let callbacks = subscriptions[terminalID]?.values else {
            return
        }
        for callback in callbacks {
            callback(terminalID, data)
        }
    }
}

enum PTYTerminalError: Error {
    case openPTYFailed(errno: Int32)
    case forkFailed(errno: Int32)
    case execFailed
    case writeFailed(errno: Int32)
    case resizeFailed(errno: Int32)
}

@MainActor
final class PTYTerminalSession {
    let id = UUID()
    let createdAt = Date()

    private let create: TerminalCreate
    private let onOutput: (UUID, Data) -> Void
    private let onExit: (UUID) -> Void
    private var masterFD: Int32 = -1
    private var childPID: pid_t = -1
    private var outputSource: DispatchSourceRead?
    private var currentCols: UInt16
    private var currentRows: UInt16
    private(set) var lastActiveAt: Date
    private var outputBuffer = Data()
    private let maxOutputBufferBytes = 512 * 1024

    init(
        create: TerminalCreate,
        onOutput: @escaping (UUID, Data) -> Void,
        onExit: @escaping (UUID) -> Void
    ) throws {
        self.create = create
        self.onOutput = onOutput
        self.onExit = onExit
        self.currentCols = create.cols
        self.currentRows = create.rows
        self.lastActiveAt = createdAt
        try open()
    }

    var listItem: TerminalListItem {
        TerminalListItem(
            terminalID: id,
            title: terminalTitle,
            shell: create.shell,
            cwd: create.cwd,
            cols: currentCols,
            rows: currentRows,
            state: .running,
            createdAt: createdAt,
            lastActiveAt: lastActiveAt
        )
    }

    func markActive() {
        lastActiveAt = Date()
    }

    func outputReplay() -> Data {
        outputBuffer
    }

    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: .main)
        source.setEventHandler { [weak self] in
            self?.readAvailableOutput()
        }
        source.setCancelHandler { [masterFD] in
            if masterFD >= 0 {
                Darwin.close(masterFD)
            }
        }
        outputSource = source
        source.resume()
    }

    func write(_ data: Data) throws {
        guard !data.isEmpty else { return }
        markActive()
        let written = data.withUnsafeBytes { rawBuffer in
            Darwin.write(masterFD, rawBuffer.baseAddress, data.count)
        }
        if written < 0 {
            throw PTYTerminalError.writeFailed(errno: errno)
        }
    }

    func resize(cols: UInt16, rows: UInt16) throws {
        var size = winsize(
            ws_row: rows,
            ws_col: cols,
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        let result = ioctl(masterFD, TIOCSWINSZ, &size)
        if result < 0 {
            throw PTYTerminalError.resizeFailed(errno: errno)
        }
        currentCols = cols
        currentRows = rows
        markActive()
    }

    func close() {
        outputSource?.cancel()
        outputSource = nil
        if childPID > 0 {
            kill(childPID, SIGHUP)
        }
    }

    private func open() throws {
        var master: Int32 = 0
        var slave: Int32 = 0
        var size = winsize(
            ws_row: create.rows,
            ws_col: create.cols,
            ws_xpixel: 0,
            ws_ypixel: 0
        )

        guard openpty(&master, &slave, nil, nil, &size) == 0 else {
            throw PTYTerminalError.openPTYFailed(errno: errno)
        }

        do {
            childPID = try spawnShell(masterFD: master, slaveFD: slave)
        } catch {
            Darwin.close(master)
            Darwin.close(slave)
            throw error
        }

        Darwin.close(slave)
        masterFD = master
    }

    private func readAvailableOutput() {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        let count = Darwin.read(masterFD, &buffer, buffer.count)
        if count > 0 {
            let data = Data(buffer.prefix(count))
            appendOutputBuffer(data)
            onOutput(id, data)
        } else {
            outputSource?.cancel()
            outputSource = nil
            onExit(id)
        }
    }

    private func appendOutputBuffer(_ data: Data) {
        outputBuffer.append(data)
        if outputBuffer.count > maxOutputBufferBytes {
            outputBuffer.removeFirst(outputBuffer.count - maxOutputBufferBytes)
        }
    }

    private var terminalTitle: String {
        let shellName = URL(fileURLWithPath: create.shell).lastPathComponent
        if let cwd = create.cwd {
            return "\(shellName) - \(URL(fileURLWithPath: cwd).lastPathComponent)"
        }
        return shellName
    }

    private func spawnShell(masterFD: Int32, slaveFD: Int32) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }

        posix_spawn_file_actions_adddup2(&actions, slaveFD, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, slaveFD, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, slaveFD, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, masterFD)
        if slaveFD > STDERR_FILENO {
            posix_spawn_file_actions_addclose(&actions, slaveFD)
        }
        if let cwd = create.cwd {
            posix_spawn_file_actions_addchdir_np(&actions, cwd)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }

        let flags = Int16(POSIX_SPAWN_SETSID)
        posix_spawnattr_setflags(&attributes, flags)

        var pid: pid_t = 0
        let arguments = [create.shell, "-i"]
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in create.env {
            environment[key] = value
        }
        let environmentEntries = environment.map { "\($0.key)=\($0.value)" }

        let result = try withCStringArray(arguments) { argv in
            try withCStringArray(environmentEntries) { envp in
                create.shell.withCString { shellPath in
                    posix_spawn(&pid, shellPath, &actions, &attributes, argv, envp)
                }
            }
        }

        guard result == 0 else {
            throw PTYTerminalError.forkFailed(errno: result)
        }

        return pid
    }
}

private func withCStringArray<Result>(
    _ strings: [String],
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
) throws -> Result {
    let cStrings = strings.map { strdup($0) }
    defer {
        for cString in cStrings {
            free(cString)
        }
    }

    var pointers = cStrings
    pointers.append(nil)
    return try pointers.withUnsafeMutableBufferPointer { buffer in
        try body(buffer.baseAddress!)
    }
}

struct ProxiedBrowserResponse {
    var response: BrowserResponse
    var body: Data
}

enum BrowserProxyError: Error {
    case invalidURL
    case invalidResponse
}

enum BrowserHTTPProxy {
    static func perform(_ request: BrowserRequest, body: Data) async throws -> ProxiedBrowserResponse {
        guard var components = URLComponents(string: "\(request.target.scheme)://\(request.target.host)") else {
            throw BrowserProxyError.invalidURL
        }
        components.port = Int(request.target.port)
        components.percentEncodedPath = request.target.path.hasPrefix("/")
            ? request.target.path
            : "/" + request.target.path

        guard let url = components.url else {
            throw BrowserProxyError.invalidURL
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        if !body.isEmpty {
            urlRequest.httpBody = body
        }

        let (responseBody, response) = try await URLSession.shared.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BrowserProxyError.invalidResponse
        }

        let headers = httpResponse.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            guard let key = entry.key as? String else { return }
            result[key] = String(describing: entry.value)
        }

        return ProxiedBrowserResponse(
            response: BrowserResponse(status: httpResponse.statusCode, headers: headers),
            body: responseBody
        )
    }
}

private extension Data {
    static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity(count)
        for _ in 0..<count {
            bytes.append(UInt8.random(in: UInt8.min...UInt8.max))
        }
        return Data(bytes)
    }
}
