import Foundation
import Network
import RemotePadProtocol

final class TerminalClient: @unchecked Sendable {
    private let agentHost: String
    private let agentPort: UInt16
    private let identity: AppIdentity
    private let queue = DispatchQueue(label: "RemotePad.iPad.TerminalClient")
    private let decoder = FrameStreamDecoder()
    private let onStatus: @Sendable (String) -> Void
    private let onOutput: @Sendable (String) -> Void

    private var connection: NWConnection?
    private var clientNonce: Data?
    private var serverDeviceID: UUID?
    private var serverNonce: Data?
    private var terminalID: UUID?
    private var didSendAuthProof = false
    private var didCreateTerminal = false
    private var isClosed = false

    init(
        agentHost: String,
        agentPort: UInt16,
        identity: AppIdentity,
        onStatus: @escaping @Sendable (String) -> Void,
        onOutput: @escaping @Sendable (String) -> Void
    ) {
        self.agentHost = agentHost
        self.agentPort = agentPort
        self.identity = identity
        self.onStatus = onStatus
        self.onOutput = onOutput
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
        queue.async { [weak self] in
            guard let self, let terminalID = self.terminalID else { return }
            self.sendToAgent(
                TerminalInput(terminalID: terminalID),
                type: .data,
                channelID: 2,
                requestID: 4,
                payload: Data(text.utf8)
            )
        }
    }

    func close() {
        queue.async { [weak self] in
            self?.closeOnQueue(sendTerminalClose: true)
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
            closeOnQueue(sendTerminalClose: false)
        case .cancelled:
            onStatus("Disconnected")
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
                self.closeOnQueue(sendTerminalClose: false)
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
                    self.closeOnQueue(sendTerminalClose: false)
                    return
                }
            }

            if isComplete {
                self.closeOnQueue(sendTerminalClose: false)
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
                closeOnQueue(sendTerminalClose: false)
                return
            }
            onStatus("Authenticated")
            createTerminal()
        case "terminal.created":
            let created = try FrameCodec.decodeHeader(TerminalCreated.self, from: frame)
            terminalID = created.terminalID
            onStatus("Terminal ready")
        case "terminal.output":
            onOutput(String(decoding: frame.payload, as: UTF8.self))
        case "terminal.closed":
            let closed = try FrameCodec.decodeHeader(TerminalClosed.self, from: frame)
            onStatus("Terminal closed: \(closed.reason ?? "closed")")
            closeOnQueue(sendTerminalClose: false)
        case "error":
            let error = try FrameCodec.decodeHeader(ProtocolErrorMessage.self, from: frame)
            onStatus("Remote error: \(error.code)")
            closeOnQueue(sendTerminalClose: false)
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

    private func createTerminal() {
        guard !didCreateTerminal else { return }
        didCreateTerminal = true

        sendToAgent(
            TerminalCreate(
                shell: "/bin/zsh",
                cwd: NSHomeDirectory(),
                cols: 100,
                rows: 30
            ),
            type: .request,
            channelID: 2,
            requestID: 3
        )
    }

    private func closeOnQueue(sendTerminalClose: Bool) {
        guard !isClosed else { return }

        if sendTerminalClose, let terminalID {
            sendTerminalCloseAndCancel(terminalID: terminalID)
            return
        }

        cancelConnection()
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
                requestID: 5
            )
            isClosed = true
            connection.send(content: data, completion: .contentProcessed { [weak self] _ in
                self?.connection?.cancel()
                self?.connection = nil
            })
        } catch {
            onStatus("Encode failed: \(error)")
            cancelConnection()
        }
    }

    private func cancelConnection() {
        isClosed = true
        connection?.cancel()
        connection = nil
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
                    self?.closeOnQueue(sendTerminalClose: false)
                }
            })
        } catch {
            onStatus("Encode failed: \(error)")
            closeOnQueue(sendTerminalClose: false)
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
