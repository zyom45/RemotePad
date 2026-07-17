import Foundation
import Network
import RemotePadProtocol

enum TerminalStartupMode: Sendable {
    case resumeOrCreate
    case create
    case attach(UUID)
}

final class TerminalClient: @unchecked Sendable {
    private let agentHost: String
    private let agentPort: UInt16
    private let identity: AppIdentity
    private let startupMode: TerminalStartupMode
    private let queue = DispatchQueue(label: "RemotePad.iPad.TerminalClient")
    private let decoder = FrameStreamDecoder()
    private let onStatus: @Sendable (String) -> Void
    private let onOutput: @Sendable (Data) -> Void
    private let onSessions: @Sendable ([TerminalListItem]) -> Void
    private let onActiveTerminal: @Sendable (UUID) -> Void
    private let onDisconnected: @Sendable () -> Void

    private var connection: NWConnection?
    private var clientNonce: Data?
    private var serverDeviceID: UUID?
    private var serverNonce: Data?
    private var terminalID: UUID?
    private var didSendAuthProof = false
    private var didRunStartupAction = false
    private var shouldRecoverFromMissingTerminal = false
    private var isAuthenticated = false
    private var isClosed = false
    private var didNotifyDisconnected = false
    private var nextRequestID: UInt32 = 3

    init(
        agentHost: String,
        agentPort: UInt16,
        identity: AppIdentity,
        startupMode: TerminalStartupMode = .resumeOrCreate,
        onStatus: @escaping @Sendable (String) -> Void,
        onOutput: @escaping @Sendable (Data) -> Void,
        onSessions: @escaping @Sendable ([TerminalListItem]) -> Void,
        onActiveTerminal: @escaping @Sendable (UUID) -> Void,
        onDisconnected: @escaping @Sendable () -> Void
    ) {
        self.agentHost = agentHost
        self.agentPort = agentPort
        self.identity = identity
        self.startupMode = startupMode
        self.onStatus = onStatus
        self.onOutput = onOutput
        self.onSessions = onSessions
        self.onActiveTerminal = onActiveTerminal
        self.onDisconnected = onDisconnected
    }

    func connect() {
        guard connection == nil else { return }

        let connection = NWConnection(
            host: NWEndpoint.Host(agentHost),
            port: NWEndpoint.Port(rawValue: agentPort)!,
            using: .tcp
        )
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            self?.handleState(state)
        }
        connection.start(queue: queue)
        onStatus("Connecting")
    }

    func sendInput(_ text: String) {
        sendData(Data(text.utf8))
    }

    func sendData(_ data: Data) {
        queue.async { [weak self] in
            guard let self, let terminalID = self.terminalID else { return }
            self.sendToAgent(
                TerminalInput(terminalID: terminalID),
                type: .data,
                channelID: 2,
                requestID: self.takeRequestID(),
                payload: data
            )
        }
    }

    func resize(cols: Int, rows: Int) {
        queue.async { [weak self] in
            guard let self, let terminalID = self.terminalID else { return }
            let safeCols = UInt16(min(max(cols, 1), Int(UInt16.max)))
            let safeRows = UInt16(min(max(rows, 1), Int(UInt16.max)))
            self.sendToAgent(
                TerminalResize(terminalID: terminalID, cols: safeCols, rows: safeRows),
                type: .request,
                channelID: 2,
                requestID: self.takeRequestID()
            )
        }
    }

    func refreshSessions() {
        queue.async { [weak self] in
            guard let self, self.isAuthenticated else { return }
            self.sendTerminalList()
        }
    }

    /// Disconnects the transport while leaving the Mac PTY running for later attachment.
    func disconnect() {
        queue.async { [weak self] in
            self?.cancelConnection()
        }
    }

    /// Explicitly closes the active Mac PTY and then disconnects the transport.
    func terminate() {
        queue.async { [weak self] in
            guard let self else { return }
            guard let terminalID = self.terminalID else {
                self.cancelConnection()
                return
            }
            self.sendTerminalCloseAndCancel(terminalID: terminalID)
        }
    }

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            onStatus("Connected")
            sendClientHello()
            receive()
        case .failed(let error):
            onStatus("Connection failed: \(error)")
            cancelConnection()
        case .cancelled:
            notifyDisconnected()
        default:
            break
        }
    }

    private func sendClientHello() {
        let nonce = Data.randomBytes(count: 32)
        clientNonce = nonce
        sendToAgent(
            ClientHello(
                deviceID: identity.deviceID,
                nonce: nonce,
                publicKey: identity.publicKey
            ),
            type: .request,
            channelID: 1,
            requestID: 1
        )
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.onStatus("Receive failed: \(error)")
                self.cancelConnection()
                return
            }

            if let data, !data.isEmpty {
                do {
                    let frames = try self.decoder.append(data)
                    for frame in frames {
                        try self.handleFrame(frame)
                    }
                } catch {
                    self.onStatus("Protocol error: \(error)")
                    self.cancelConnection()
                    return
                }
            }

            if isComplete {
                self.cancelConnection()
            } else if !self.isClosed {
                self.receive()
            }
        }
    }

    private func handleFrame(_ frame: Frame) throws {
        let header = try FrameCodec.decodeHeader(MessageHeader.self, from: frame)
        switch header.kind {
        case "server.hello":
            let hello = try FrameCodec.decodeHeader(ServerHello.self, from: frame)
            serverDeviceID = hello.deviceID
            serverNonce = hello.nonce
            sendAuthProof()
        case "auth.result":
            let result = try FrameCodec.decodeHeader(AuthResult.self, from: frame)
            guard result.accepted else {
                onStatus("Auth rejected: \(result.reason ?? "unknown")")
                cancelConnection()
                return
            }
            isAuthenticated = true
            onStatus("Authenticated")
            runStartupAction()
        case "terminal.list.result":
            let result = try FrameCodec.decodeHeader(TerminalListResult.self, from: frame)
            onSessions(result.terminals)
            if shouldRecoverFromMissingTerminal || shouldResumeOrCreate {
                shouldRecoverFromMissingTerminal = false
                didRunStartupAction = true
                resumeOrCreate(from: result.terminals)
            }
        case "terminal.created":
            let created = try FrameCodec.decodeHeader(TerminalCreated.self, from: frame)
            terminalID = created.terminalID
            onActiveTerminal(created.terminalID)
            onStatus("Terminal ready")
            sendTerminalList()
        case "terminal.attached":
            let attached = try FrameCodec.decodeHeader(TerminalAttached.self, from: frame)
            terminalID = attached.terminal.terminalID
            onActiveTerminal(attached.terminal.terminalID)
            onStatus("Terminal resumed")
        case "terminal.output":
            let output = try FrameCodec.decodeHeader(TerminalOutput.self, from: frame)
            if terminalID == nil || terminalID == output.terminalID {
                onOutput(frame.payload)
            }
        case "terminal.closed":
            let closed = try FrameCodec.decodeHeader(TerminalClosed.self, from: frame)
            onStatus("Terminal closed: \(closed.reason ?? "closed")")
            terminalID = nil
            cancelConnection()
        case "error":
            let error = try FrameCodec.decodeHeader(ProtocolErrorMessage.self, from: frame)
            if error.code == "terminal_not_found" {
                terminalID = nil
                shouldRecoverFromMissingTerminal = true
                onStatus("Terminal ended; finding another session")
                sendTerminalList()
                return
            }
            onStatus("Remote error: \(error.code)")
            cancelConnection()
        default:
            break
        }
    }

    private func sendAuthProof() {
        guard !didSendAuthProof, let clientNonce, let serverDeviceID, let serverNonce else {
            return
        }
        didSendAuthProof = true

        let transcript = AuthTranscript.make(
            clientDeviceID: identity.deviceID,
            clientNonce: clientNonce,
            serverDeviceID: serverDeviceID,
            serverNonce: serverNonce
        )
        sendToAgent(
            AuthProof(signature: identity.sign(transcript)),
            type: .request,
            channelID: 1,
            requestID: 2
        )
    }

    private func runStartupAction() {
        switch startupMode {
        case .resumeOrCreate:
            sendTerminalList()
        case .create:
            didRunStartupAction = true
            createTerminal()
        case .attach(let terminalID):
            didRunStartupAction = true
            attachTerminal(terminalID)
        }
    }

    private func sendTerminalList() {
        sendToAgent(
            TerminalList(),
            type: .request,
            channelID: 2,
            requestID: takeRequestID()
        )
    }

    private var shouldResumeOrCreate: Bool {
        guard !didRunStartupAction else { return false }
        if case .resumeOrCreate = startupMode { return true }
        return false
    }

    private func resumeOrCreate(from terminals: [TerminalListItem]) {
        if let terminal = terminals
            .filter({ $0.state == .running })
            .max(by: { $0.lastActiveAt < $1.lastActiveAt }) {
            attachTerminal(terminal.terminalID)
        } else {
            createTerminal()
        }
    }

    private func createTerminal() {
        sendToAgent(
            TerminalCreate(
                shell: "/bin/zsh",
                cwd: NSHomeDirectory(),
                cols: 100,
                rows: 30
            ),
            type: .request,
            channelID: 2,
            requestID: takeRequestID()
        )
    }

    private func attachTerminal(_ terminalID: UUID) {
        sendToAgent(
            TerminalAttach(terminalID: terminalID),
            type: .request,
            channelID: 2,
            requestID: takeRequestID()
        )
    }

    private func sendTerminalCloseAndCancel(terminalID: UUID) {
        guard let connection else {
            cancelConnection()
            return
        }

        do {
            let data = try FrameCodec.encodeHeader(
                TerminalClose(terminalID: terminalID),
                type: .request,
                channelID: 2,
                requestID: takeRequestID()
            )
            isClosed = true
            connection.send(content: data, completion: .contentProcessed { [weak self] _ in
                self?.connection?.cancel()
                self?.connection = nil
                self?.notifyDisconnected()
            })
        } catch {
            onStatus("Encode failed: \(error)")
            cancelConnection()
        }
    }

    private func cancelConnection() {
        guard !isClosed else {
            notifyDisconnected()
            return
        }
        isClosed = true
        connection?.cancel()
        connection = nil
        notifyDisconnected()
    }

    private func notifyDisconnected() {
        guard !didNotifyDisconnected else { return }
        didNotifyDisconnected = true
        onDisconnected()
    }

    private func takeRequestID() -> UInt32 {
        defer { nextRequestID &+= 1 }
        return nextRequestID
    }

    private func sendToAgent<Header: Encodable>(
        _ header: Header,
        type: FrameType,
        channelID: UInt32,
        requestID: UInt32,
        payload: Data = Data()
    ) {
        guard !isClosed, let connection else { return }
        do {
            let data = try FrameCodec.encodeHeader(
                header,
                type: type,
                channelID: channelID,
                requestID: requestID,
                payload: payload
            )
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.onStatus("Send failed: \(error)")
                    self?.cancelConnection()
                }
            })
        } catch {
            onStatus("Encode failed: \(error)")
            cancelConnection()
        }
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
