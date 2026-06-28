import Foundation
import CryptoKit
import Network
import RemotePadProtocol

@main
struct RemotePadDevClientCommand {
    static func main() async throws {
        if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--local-proxy" {
            try await runLocalProxy(arguments: CommandLine.arguments)
            return
        }

        if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--pair" {
            try await runPairing(arguments: CommandLine.arguments)
            return
        }

        if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--pair-status" {
            try await runPairingStatus(arguments: CommandLine.arguments)
            return
        }

        if handleUtilityCommand(arguments: CommandLine.arguments) {
            return
        }

        guard CommandLine.arguments.count >= 2, let port = UInt16(CommandLine.arguments[1]) else {
            printUsage()
            return
        }

        let mode = parseMode(arguments: CommandLine.arguments)
        let client = DevClient(
            port: port,
            mode: mode,
            closeAfterReady: CommandLine.arguments.contains("--close-after-ready")
        )
        try await client.run()
    }

    private static func handleUtilityCommand(arguments: [String]) -> Bool {
        guard arguments.count >= 2 else { return false }

        switch arguments[1] {
        case "--identity":
            let identity = DevClientIdentity.loadOrCreate()
            print("device_id: \(identity.deviceID)")
            print("public_key: \(identity.publicKey.base64EncodedString())")
            print("fingerprint: \(fingerprint(identity.publicKey))")
            return true

        case "--reset-identity":
            DevClientIdentity.reset()
            let identity = DevClientIdentity.loadOrCreate()
            print("reset identity")
            print("device_id: \(identity.deviceID)")
            print("public_key: \(identity.publicKey.base64EncodedString())")
            print("fingerprint: \(fingerprint(identity.publicKey))")
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
          swift run remotepad-dev-client <port> [--attach-first] [--close-after-ready] [--browser-get <local-port> [path]] [--browser-stream-get <local-port> [path]]
          swift run remotepad-dev-client --local-proxy <agent-port> <listen-port> <target-port>
          swift run remotepad-dev-client --pair <agent-port> [device-name]
          swift run remotepad-dev-client --pair-status <agent-port>
          swift run remotepad-dev-client --identity
          swift run remotepad-dev-client --reset-identity
        """)
    }

    private static func runLocalProxy(arguments: [String]) async throws {
        guard arguments.count == 5,
              let agentPort = UInt16(arguments[2]),
              let listenPort = UInt16(arguments[3]),
              let targetPort = UInt16(arguments[4]) else {
            print("usage: swift run remotepad-dev-client --local-proxy <agent-port> <listen-port> <target-port>")
            return
        }

        let proxy = try LocalBrowserProxy(
            agentPort: agentPort,
            listenPort: listenPort,
            target: BrowserTarget(scheme: "tcp", host: "127.0.0.1", port: targetPort, path: "")
        )
        proxy.start()
        print("local proxy ready")
        print("  listen: http://127.0.0.1:\(listenPort)")
        print("  target: Mac 127.0.0.1:\(targetPort)")
        print("  agent: 127.0.0.1:\(agentPort)")
        while !Task.isCancelled {
            try await Task.sleep(for: .seconds(60))
        }
    }

    private static func runPairing(arguments: [String]) async throws {
        guard arguments.count >= 3, let agentPort = UInt16(arguments[2]) else {
            print("usage: swift run remotepad-dev-client --pair <agent-port> [device-name]")
            return
        }

        let deviceName = arguments.indices.contains(3) ? arguments[3] : Host.current().localizedName ?? "RemotePad Dev Client"
        let client = DevPairingClient(
            agentPort: agentPort,
            identity: .loadOrCreate(),
            deviceName: deviceName
        )
        let result = try await client.run()
        print("pairing result")
        print("  accepted: \(result.accepted)")
        print("  status: \(result.status)")
        print("  device_id: \(result.deviceID)")
        if let reason = result.reason {
            print("  reason: \(reason)")
        }
    }

    private static func runPairingStatus(arguments: [String]) async throws {
        guard arguments.count == 3, let agentPort = UInt16(arguments[2]) else {
            print("usage: swift run remotepad-dev-client --pair-status <agent-port>")
            return
        }

        let identity = DevClientIdentity.loadOrCreate()
        let client = DevPairingStatusClient(agentPort: agentPort, deviceID: identity.deviceID)
        let result = try await client.run()
        print("pairing status")
        print("  accepted: \(result.accepted)")
        print("  status: \(result.status)")
        print("  device_id: \(result.deviceID)")
        if let reason = result.reason {
            print("  reason: \(reason)")
        }
    }

    private static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func parseMode(arguments: [String]) -> DevClientMode {
        if let index = arguments.firstIndex(of: "--browser-get"),
           arguments.indices.contains(index + 1),
           let port = UInt16(arguments[index + 1]) {
            let path = arguments.indices.contains(index + 2) && !arguments[index + 2].hasPrefix("--")
                ? arguments[index + 2]
                : "/"
            return .browserGet(BrowserTarget(port: port, path: path))
        }

        if let index = arguments.firstIndex(of: "--browser-stream-get"),
           arguments.indices.contains(index + 1),
           let port = UInt16(arguments[index + 1]) {
            let path = arguments.indices.contains(index + 2) && !arguments[index + 2].hasPrefix("--")
                ? arguments[index + 2]
                : "/"
            return .browserStreamGet(BrowserTarget(scheme: "tcp", port: port, path: path))
        }

        return arguments.contains("--attach-first") ? .attachFirst : .create
    }
}

enum DevClientMode {
    case create
    case attachFirst
    case browserGet(BrowserTarget)
    case browserStreamGet(BrowserTarget)
}

final class DevClient: @unchecked Sendable {
    private let port: UInt16
    private let mode: DevClientMode
    private let closeAfterReady: Bool
    private let identity: DevClientIdentity
    private let decoder = FrameStreamDecoder()
    private let queue = DispatchQueue(label: "RemotePadDevClient")
    private var connection: NWConnection?
    private var clientNonce: Data?
    private var serverDeviceID: UUID?
    private var serverNonce: Data?
    private var didSendAuthProof = false
    private var didSendTerminalCreate = false
    private var didSendTerminalList = false
    private var didSendTerminalClose = false
    private var didSendBrowserStreamOpen = false
    private var didFinish = false
    private var terminalOutputBuffer = ""
    private var activeTerminalID: UUID?
    private var activeBrowserStreamID: UUID?

    init(port: UInt16, mode: DevClientMode, closeAfterReady: Bool) {
        self.port = port
        self.mode = mode
        self.closeAfterReady = closeAfterReady
        self.identity = DevClientIdentity.loadOrCreate()
    }

    func run() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let connection = NWConnection(
                host: "127.0.0.1",
                port: NWEndpoint.Port(rawValue: port)!,
                using: .tcp
            )
            self.connection = connection

            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.sendClientHello(on: connection)
                    self.receive(on: connection, continuation: continuation)
                case .failed(let error):
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }

            connection.start(queue: queue)
        }
    }

    private func sendClientHello(on connection: NWConnection) {
        let nonce = Data.randomBytes(count: 32)
        clientNonce = nonce
        let hello = ClientHello(
            deviceID: identity.deviceID,
            nonce: nonce,
            publicKey: identity.publicKey
        )
        do {
            let data = try FrameCodec.encodeHeader(
                hello,
                type: .request,
                channelID: 1,
                requestID: 1
            )
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    print("send failed: \(error)")
                }
            })
        } catch {
            print("encode failed: \(error)")
        }
    }

    private func receive(
        on connection: NWConnection,
        continuation: CheckedContinuation<Void, Error>
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, error in
            guard let self else { return }

            if let error {
                continuation.resume(throwing: error)
                return
            }

            guard let data, !data.isEmpty else {
                continuation.resume()
                return
            }

            do {
                let frames = try self.decoder.append(data)
                for frame in frames {
                    let header = try FrameCodec.decodeHeader(MessageHeader.self, from: frame)
                    if header.kind == "server.hello" {
                        let hello = try FrameCodec.decodeHeader(ServerHello.self, from: frame)
                        print("received server.hello")
                        print("  device_id: \(hello.deviceID)")
                        print("  protocol: \(hello.capabilities.protocolVersion)")
                        print("  capabilities: \(hello.capabilities.channels.map(\.rawValue).joined(separator: ","))")
                        self.serverDeviceID = hello.deviceID
                        self.serverNonce = hello.nonce
                        self.sendAuthProof(on: connection)
                    } else if header.kind == "auth.result" {
                        let result = try FrameCodec.decodeHeader(AuthResult.self, from: frame)
                        print("received auth.result")
                        print("  accepted: \(result.accepted)")
                        if let sessionID = result.sessionID {
                            print("  session_id: \(sessionID)")
                        }
                        if result.accepted {
                            switch self.mode {
                            case .create:
                                self.sendTerminalCreate(on: connection)
                            case .attachFirst:
                                self.sendTerminalList(on: connection)
                            case .browserGet(let target):
                                self.sendBrowserRequest(target: target, on: connection)
                            case .browserStreamGet(let target):
                                self.sendBrowserStreamGet(target: target, on: connection)
                            }
                        } else {
                            self.finish(connection: connection, continuation: continuation)
                            return
                        }
                    } else if header.kind == "terminal.created" {
                        let created = try FrameCodec.decodeHeader(TerminalCreated.self, from: frame)
                        print("received terminal.created")
                        print("  terminal_id: \(created.terminalID)")
                        self.activeTerminalID = created.terminalID
                        self.sendTerminalList(on: connection)
                        self.sendTerminalInput(
                            terminalID: created.terminalID,
                            text: "stty -echo\n",
                            on: connection
                        )
                        self.queue.asyncAfter(deadline: .now() + 0.2) {
                            self.sendTerminalInput(
                                terminalID: created.terminalID,
                                text: "printf '\\137\\137REMOTEPAD_READY\\137\\137\\012'\n",
                                on: connection
                            )
                        }
                    } else if header.kind == "terminal.output" {
                        let output = String(decoding: frame.payload, as: UTF8.self)
                        print("received terminal.output")
                        print(output, terminator: "")
                        self.terminalOutputBuffer += output
                        if self.shouldFinishFromTerminalOutput() {
                            if self.closeAfterReady, let terminalID = self.activeTerminalID {
                                self.sendTerminalClose(terminalID: terminalID, on: connection)
                                continue
                            }
                            self.finish(connection: connection, continuation: continuation)
                            return
                        }
                    } else if header.kind == "terminal.closed" {
                        let closed = try FrameCodec.decodeHeader(TerminalClosed.self, from: frame)
                        print("received terminal.closed")
                        print("  terminal_id: \(closed.terminalID)")
                        if let reason = closed.reason {
                            print("  reason: \(reason)")
                        }
                        self.finish(connection: connection, continuation: continuation)
                        return
                    } else if header.kind == "browser.response" {
                        let response = try FrameCodec.decodeHeader(BrowserResponse.self, from: frame)
                        print("received browser.response")
                        print("  status: \(response.status)")
                        if let contentType = response.headers["Content-Type"] ?? response.headers["content-type"] {
                            print("  content-type: \(contentType)")
                        }
                        print(String(decoding: frame.payload, as: UTF8.self), terminator: "")
                        self.finish(connection: connection, continuation: continuation)
                        return
                    } else if header.kind == "browser.stream.data" {
                        let data = try FrameCodec.decodeHeader(BrowserStreamData.self, from: frame)
                        print("received browser.stream.data")
                        print("  stream_id: \(data.streamID)")
                        print(String(decoding: frame.payload, as: UTF8.self), terminator: "")
                    } else if header.kind == "browser.stream.close" {
                        let close = try FrameCodec.decodeHeader(BrowserStreamClose.self, from: frame)
                        print("received browser.stream.close")
                        print("  stream_id: \(close.streamID)")
                        if let reason = close.reason {
                            print("  reason: \(reason)")
                        }
                        self.finish(connection: connection, continuation: continuation)
                        return
                    } else if header.kind == "terminal.list.result" {
                        let result = try FrameCodec.decodeHeader(TerminalListResult.self, from: frame)
                        print("received terminal.list.result")
                        print("  terminals: \(result.terminals.count)")
                        for item in result.terminals {
                            print("  - \(item.terminalID) \(item.title) \(item.state.rawValue)")
                        }
                        if case .attachFirst = self.mode {
                            if let first = result.terminals.first {
                                self.sendTerminalAttach(terminalID: first.terminalID, on: connection)
                            } else {
                                print("no terminal to attach")
                                self.finish(connection: connection, continuation: continuation)
                                return
                            }
                        }
                    } else if header.kind == "terminal.attached" {
                        let attached = try FrameCodec.decodeHeader(TerminalAttached.self, from: frame)
                        print("received terminal.attached")
                        print("  terminal_id: \(attached.terminal.terminalID)")
                        self.activeTerminalID = attached.terminal.terminalID
                        self.queue.asyncAfter(deadline: .now() + 0.2) {
                            self.sendTerminalInput(
                                terminalID: attached.terminal.terminalID,
                                text: "printf '\\137\\137REMOTEPAD_ATTACHED\\137\\137\\012'\n",
                                on: connection
                            )
                        }
                    } else {
                        print("received \(header.kind)")
                    }
                }

                self.receive(on: connection, continuation: continuation)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func sendAuthProof(on connection: NWConnection) {
        guard !didSendAuthProof else { return }
        didSendAuthProof = true

        guard let clientNonce, let serverDeviceID, let serverNonce else {
            print("auth proof skipped: missing challenge material")
            return
        }

        let transcript = AuthTranscript.make(
            clientDeviceID: identity.deviceID,
            clientNonce: clientNonce,
            serverDeviceID: serverDeviceID,
            serverNonce: serverNonce
        )
        let proof = AuthProof(signature: identity.sign(transcript))
        do {
            let data = try FrameCodec.encodeHeader(
                proof,
                type: .request,
                channelID: 1,
                requestID: 2
            )
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    print("auth proof send failed: \(error)")
                }
            })
        } catch {
            print("auth proof encode failed: \(error)")
        }
    }

    private func sendTerminalCreate(on connection: NWConnection) {
        guard !didSendTerminalCreate else { return }
        didSendTerminalCreate = true

        let create = TerminalCreate(
            shell: "/bin/zsh",
            cwd: FileManager.default.currentDirectoryPath,
            cols: 100,
            rows: 30
        )
        do {
            let data = try FrameCodec.encodeHeader(
                create,
                type: .request,
                channelID: 2,
                requestID: 3
            )
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    print("terminal create send failed: \(error)")
                }
            })
        } catch {
            print("terminal create encode failed: \(error)")
        }
    }

    private func sendTerminalList(on connection: NWConnection) {
        guard !didSendTerminalList else { return }
        didSendTerminalList = true

        do {
            let data = try FrameCodec.encodeHeader(
                TerminalList(),
                type: .request,
                channelID: 2,
                requestID: 5
            )
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    print("terminal list send failed: \(error)")
                }
            })
        } catch {
            print("terminal list encode failed: \(error)")
        }
    }

    private func sendTerminalInput(terminalID: UUID, text: String, on connection: NWConnection) {
        let input = TerminalInput(terminalID: terminalID)
        do {
            let data = try FrameCodec.encodeHeader(
                input,
                type: .data,
                channelID: 2,
                requestID: 4,
                payload: Data(text.utf8)
            )
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    print("terminal input send failed: \(error)")
                }
            })
        } catch {
            print("terminal input encode failed: \(error)")
        }
    }

    private func sendTerminalAttach(terminalID: UUID, on connection: NWConnection) {
        let attach = TerminalAttach(terminalID: terminalID)
        do {
            let data = try FrameCodec.encodeHeader(
                attach,
                type: .request,
                channelID: 2,
                requestID: 6
            )
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    print("terminal attach send failed: \(error)")
                }
            })
        } catch {
            print("terminal attach encode failed: \(error)")
        }
    }

    private func sendTerminalClose(terminalID: UUID, on connection: NWConnection) {
        guard !didSendTerminalClose else { return }
        didSendTerminalClose = true

        let close = TerminalClose(terminalID: terminalID)
        do {
            let data = try FrameCodec.encodeHeader(
                close,
                type: .request,
                channelID: 2,
                requestID: 7
            )
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    print("terminal close send failed: \(error)")
                }
            })
        } catch {
            print("terminal close encode failed: \(error)")
        }
    }

    private func shouldFinishFromTerminalOutput() -> Bool {
        switch mode {
        case .create:
            terminalOutputBuffer.contains("__REMOTEPAD_READY__")
        case .attachFirst:
            terminalOutputBuffer.contains("__REMOTEPAD_ATTACHED__")
        case .browserGet:
            false
        case .browserStreamGet:
            false
        }
    }

    private func sendBrowserRequest(target: BrowserTarget, on connection: NWConnection) {
        let request = BrowserRequest(
            method: "GET",
            target: target,
            headers: ["Accept": "*/*"]
        )
        do {
            let data = try FrameCodec.encodeHeader(
                request,
                type: .request,
                channelID: 3,
                requestID: 8
            )
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    print("browser request send failed: \(error)")
                }
            })
        } catch {
            print("browser request encode failed: \(error)")
        }
    }

    private func sendBrowserStreamGet(target: BrowserTarget, on connection: NWConnection) {
        guard !didSendBrowserStreamOpen else { return }
        didSendBrowserStreamOpen = true

        let streamID = UUID()
        activeBrowserStreamID = streamID
        let open = BrowserStreamOpen(streamID: streamID, target: target)
        let requestText = """
        GET \(target.path.isEmpty ? "/" : target.path) HTTP/1.1\r
        Host: \(target.host):\(target.port)\r
        Connection: close\r
        Accept: */*\r
        \r

        """

        do {
            let openData = try FrameCodec.encodeHeader(
                open,
                type: .request,
                channelID: 3,
                requestID: 9
            )
            let streamData = try FrameCodec.encodeHeader(
                BrowserStreamData(streamID: streamID),
                type: .data,
                channelID: 3,
                requestID: 10,
                payload: Data(requestText.utf8)
            )
            connection.send(content: openData, completion: .contentProcessed { error in
                if let error {
                    print("browser stream open send failed: \(error)")
                }
            })
            connection.send(content: streamData, completion: .contentProcessed { error in
                if let error {
                    print("browser stream data send failed: \(error)")
                }
            })
        } catch {
            print("browser stream encode failed: \(error)")
        }
    }

    private func finish(
        connection: NWConnection,
        continuation: CheckedContinuation<Void, Error>
    ) {
        guard !didFinish else { return }
        didFinish = true
        connection.cancel()
        continuation.resume()
    }
}

final class LocalBrowserProxy: @unchecked Sendable {
    private let agentPort: UInt16
    private let listenPort: UInt16
    private let target: BrowserTarget
    private let identity = DevClientIdentity.loadOrCreate()
    private let queue = DispatchQueue(label: "RemotePadLocalBrowserProxy")
    private let listener: NWListener
    private var connections: [UUID: LocalBrowserProxyConnection] = [:]

    init(agentPort: UInt16, listenPort: UInt16, target: BrowserTarget) throws {
        self.agentPort = agentPort
        self.listenPort = listenPort
        self.target = target

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: listenPort)!
        )
        self.listener = try NWListener(using: parameters)
    }

    func start() {
        listener.newConnectionHandler = { [weak self] localConnection in
            guard let self else {
                localConnection.cancel()
                return
            }
            let connection = LocalBrowserProxyConnection(
                localConnection: localConnection,
                agentPort: self.agentPort,
                target: self.target,
                identity: self.identity,
                queue: self.queue,
                onClose: { [weak self] id in
                    self?.connections[id] = nil
                }
            )
            self.connections[connection.id] = connection
            connection.start()
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                print("local proxy listener failed: \(error)")
            }
        }
        listener.start(queue: queue)
    }
}

final class LocalBrowserProxyConnection: @unchecked Sendable {
    let id = UUID()

    private let localConnection: NWConnection
    private let agentConnection: NWConnection
    private let target: BrowserTarget
    private let identity: DevClientIdentity
    private let queue: DispatchQueue
    private let onClose: (UUID) -> Void
    private let decoder = FrameStreamDecoder()
    private let streamID = UUID()

    private var clientNonce: Data?
    private var serverDeviceID: UUID?
    private var serverNonce: Data?
    private var isAuthenticated = false
    private var didOpenStream = false
    private var isClosed = false
    private var pendingLocalData: [Data] = []

    init(
        localConnection: NWConnection,
        agentPort: UInt16,
        target: BrowserTarget,
        identity: DevClientIdentity,
        queue: DispatchQueue,
        onClose: @escaping (UUID) -> Void
    ) {
        self.localConnection = localConnection
        self.agentConnection = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: agentPort)!,
            using: .tcp
        )
        self.target = target
        self.identity = identity
        self.queue = queue
        self.onClose = onClose
    }

    func start() {
        localConnection.stateUpdateHandler = { [weak self] state in
            self?.handleLocalState(state)
        }
        agentConnection.stateUpdateHandler = { [weak self] state in
            self?.handleAgentState(state)
        }

        receiveLocal()
        localConnection.start(queue: queue)
        agentConnection.start(queue: queue)
    }

    private func handleLocalState(_ state: NWConnection.State) {
        switch state {
        case .failed, .cancelled:
            close()
        default:
            break
        }
    }

    private func handleAgentState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            sendClientHello()
            receiveAgent()
        case .failed(let error):
            print("local proxy agent connection failed: \(error)")
            close()
        case .cancelled:
            close()
        default:
            break
        }
    }

    private func sendClientHello() {
        let nonce = Data.randomBytes(count: 32)
        clientNonce = nonce
        let hello = ClientHello(
            deviceID: identity.deviceID,
            nonce: nonce,
            publicKey: identity.publicKey
        )
        sendToAgent(hello, type: .request, channelID: 1, requestID: 1)
    }

    private func receiveAgent() {
        agentConnection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                print("local proxy agent receive failed: \(error)")
                self.close()
                return
            }

            if let data, !data.isEmpty {
                do {
                    let frames = try self.decoder.append(data)
                    for frame in frames {
                        try self.handleAgentFrame(frame)
                    }
                } catch {
                    print("local proxy protocol error: \(error)")
                    self.close()
                    return
                }
            }

            if isComplete {
                self.close()
            } else if !self.isClosed {
                self.receiveAgent()
            }
        }
    }

    private func handleAgentFrame(_ frame: Frame) throws {
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
                print("local proxy auth rejected: \(result.reason ?? "unknown")")
                close()
                return
            }
            isAuthenticated = true
            openBrowserStream()
        case "browser.stream.data":
            _ = try FrameCodec.decodeHeader(BrowserStreamData.self, from: frame)
            sendToLocal(frame.payload)
        case "browser.stream.close":
            close()
        case "error":
            let error = try FrameCodec.decodeHeader(ProtocolErrorMessage.self, from: frame)
            print("local proxy remote error: \(error.code) \(error.message)")
            close()
        default:
            break
        }
    }

    private func sendAuthProof() {
        guard let clientNonce, let serverDeviceID, let serverNonce else {
            close()
            return
        }

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

    private func openBrowserStream() {
        guard isAuthenticated, !didOpenStream else { return }
        didOpenStream = true
        sendToAgent(
            BrowserStreamOpen(streamID: streamID, target: target),
            type: .request,
            channelID: 3,
            requestID: 3
        )
        flushPendingLocalData()
    }

    private func receiveLocal() {
        localConnection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                print("local proxy browser receive failed: \(error)")
                self.close()
                return
            }

            if let data, !data.isEmpty {
                self.handleLocalData(data)
            }

            if isComplete {
                self.sendToAgent(
                    BrowserStreamClose(streamID: self.streamID, reason: "local_eof"),
                    type: .request,
                    channelID: 3,
                    requestID: 0
                )
            } else if !self.isClosed {
                self.receiveLocal()
            }
        }
    }

    private func handleLocalData(_ data: Data) {
        guard didOpenStream else {
            pendingLocalData.append(data)
            return
        }
        sendBrowserData(data)
    }

    private func flushPendingLocalData() {
        let pending = pendingLocalData
        pendingLocalData.removeAll()
        for data in pending {
            sendBrowserData(data)
        }
    }

    private func sendBrowserData(_ data: Data) {
        sendToAgent(
            BrowserStreamData(streamID: streamID),
            type: .data,
            channelID: 3,
            requestID: 4,
            payload: data
        )
    }

    private func sendToLocal(_ data: Data) {
        guard !data.isEmpty, !isClosed else { return }
        localConnection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error {
                print("local proxy browser send failed: \(error)")
                self?.close()
            }
        })
    }

    private func sendToAgent<Header: Encodable>(
        _ header: Header,
        type: FrameType,
        channelID: UInt32,
        requestID: UInt32,
        payload: Data = Data()
    ) {
        guard !isClosed else { return }
        do {
            let data = try FrameCodec.encodeHeader(
                header,
                type: type,
                channelID: channelID,
                requestID: requestID,
                payload: payload
            )
            agentConnection.send(content: data, completion: .contentProcessed { [weak self] error in
                if let error {
                    print("local proxy agent send failed: \(error)")
                    self?.close()
                }
            })
        } catch {
            print("local proxy encode failed: \(error)")
            close()
        }
    }

    private func close() {
        guard !isClosed else { return }
        isClosed = true
        localConnection.cancel()
        agentConnection.cancel()
        onClose(id)
    }
}

struct DevPairingResult {
    var accepted: Bool
    var status: String
    var deviceID: UUID
    var reason: String?
}

final class DevPairingClient: @unchecked Sendable {
    private let agentPort: UInt16
    private let identity: DevClientIdentity
    private let deviceName: String
    private let queue = DispatchQueue(label: "RemotePadDevPairingClient")
    private let decoder = FrameStreamDecoder()

    private var connection: NWConnection?
    private var pairingIdentity: DeviceIdentity?
    private var macDeviceID: UUID?
    private var challenge: Data?
    private var continuation: CheckedContinuation<DevPairingResult, Error>?

    init(agentPort: UInt16, identity: DevClientIdentity, deviceName: String) {
        self.agentPort = agentPort
        self.identity = identity
        self.deviceName = deviceName
    }

    func run() async throws -> DevPairingResult {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let connection = NWConnection(
                host: "127.0.0.1",
                port: NWEndpoint.Port(rawValue: agentPort)!,
                using: .tcp
            )
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                self?.handleState(state)
            }
            connection.start(queue: queue)
        }
    }

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            sendPairingStart()
            receive()
        case .failed(let error):
            finish(throwing: error)
        default:
            break
        }
    }

    private func sendPairingStart() {
        let pairingIdentity = identity.deviceIdentity(deviceName: deviceName)
        self.pairingIdentity = pairingIdentity
        send(PairingStart(identity: pairingIdentity), type: .request, channelID: 1, requestID: 1)
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.finish(throwing: error)
                return
            }

            if let data, !data.isEmpty {
                do {
                    let frames = try self.decoder.append(data)
                    for frame in frames {
                        try self.handleFrame(frame)
                    }
                } catch {
                    self.finish(throwing: error)
                    return
                }
            }

            if isComplete {
                self.finish(throwing: DevPairingError.connectionClosed)
            } else {
                self.receive()
            }
        }
    }

    private func handleFrame(_ frame: Frame) throws {
        let header = try FrameCodec.decodeHeader(MessageHeader.self, from: frame)
        switch header.kind {
        case "pairing.challenge":
            let challenge = try FrameCodec.decodeHeader(PairingChallenge.self, from: frame)
            self.challenge = challenge.challenge
            macDeviceID = challenge.macIdentity.deviceID
            sendPairingResponse()
        case "pairing.result":
            let result = try FrameCodec.decodeHeader(PairingResult.self, from: frame)
            finish(returning: DevPairingResult(
                accepted: result.accepted,
                status: result.status,
                deviceID: result.deviceID,
                reason: result.reason
            ))
        case "error":
            let error = try FrameCodec.decodeHeader(ProtocolErrorMessage.self, from: frame)
            finish(throwing: DevPairingError.remote(error.code))
        default:
            break
        }
    }

    private func sendPairingResponse() {
        guard let pairingIdentity, let macDeviceID, let challenge else {
            finish(throwing: DevPairingError.missingChallenge)
            return
        }

        let transcript = PairingTranscript.make(
            challenge: challenge,
            ipadIdentity: pairingIdentity,
            macDeviceID: macDeviceID
        )
        send(
            PairingResponse(signature: identity.sign(transcript)),
            type: .request,
            channelID: 1,
            requestID: 2
        )
    }

    private func send<Header: Encodable>(
        _ header: Header,
        type: FrameType,
        channelID: UInt32,
        requestID: UInt32
    ) {
        do {
            let data = try FrameCodec.encodeHeader(header, type: type, channelID: channelID, requestID: requestID)
            connection?.send(content: data, completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.finish(throwing: error)
                }
            })
        } catch {
            finish(throwing: error)
        }
    }

    private func finish(returning result: DevPairingResult) {
        connection?.cancel()
        connection = nil
        continuation?.resume(returning: result)
        continuation = nil
    }

    private func finish(throwing error: Error) {
        connection?.cancel()
        connection = nil
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

enum DevPairingError: Error {
    case connectionClosed
    case missingChallenge
    case remote(String)
}

final class DevPairingStatusClient: @unchecked Sendable {
    private let agentPort: UInt16
    private let deviceID: UUID
    private let queue = DispatchQueue(label: "RemotePadDevPairingStatusClient")
    private let decoder = FrameStreamDecoder()

    private var connection: NWConnection?
    private var continuation: CheckedContinuation<DevPairingResult, Error>?

    init(agentPort: UInt16, deviceID: UUID) {
        self.agentPort = agentPort
        self.deviceID = deviceID
    }

    func run() async throws -> DevPairingResult {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let connection = NWConnection(
                host: "127.0.0.1",
                port: NWEndpoint.Port(rawValue: agentPort)!,
                using: .tcp
            )
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                self?.handleState(state)
            }
            connection.start(queue: queue)
        }
    }

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            sendStatusRequest()
            receive()
        case .failed(let error):
            finish(throwing: error)
        default:
            break
        }
    }

    private func sendStatusRequest() {
        do {
            let data = try FrameCodec.encodeHeader(
                PairingStatusRequest(deviceID: deviceID),
                type: .request,
                channelID: 1,
                requestID: 1
            )
            connection?.send(content: data, completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.finish(throwing: error)
                }
            })
        } catch {
            finish(throwing: error)
        }
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.finish(throwing: error)
                return
            }

            if let data, !data.isEmpty {
                do {
                    let frames = try self.decoder.append(data)
                    for frame in frames {
                        let header = try FrameCodec.decodeHeader(MessageHeader.self, from: frame)
                        if header.kind == "pairing.result" {
                            let result = try FrameCodec.decodeHeader(PairingResult.self, from: frame)
                            self.finish(returning: DevPairingResult(
                                accepted: result.accepted,
                                status: result.status,
                                deviceID: result.deviceID,
                                reason: result.reason
                            ))
                            return
                        }
                    }
                } catch {
                    self.finish(throwing: error)
                    return
                }
            }

            if isComplete {
                self.finish(throwing: DevPairingError.connectionClosed)
            } else {
                self.receive()
            }
        }
    }

    private func finish(returning result: DevPairingResult) {
        connection?.cancel()
        connection = nil
        continuation?.resume(returning: result)
        continuation = nil
    }

    private func finish(throwing error: Error) {
        connection?.cancel()
        connection = nil
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

struct DevClientIdentity {
    let deviceID: UUID
    let privateKey: Curve25519.Signing.PrivateKey

    var publicKey: Data {
        privateKey.publicKey.rawRepresentation
    }

    func deviceIdentity(deviceName: String) -> DeviceIdentity {
        DeviceIdentity(
            deviceID: deviceID,
            deviceName: deviceName,
            deviceType: .ipad,
            publicKey: publicKey,
            createdAt: Date()
        )
    }

    static func loadOrCreate() -> DevClientIdentity {
        let defaults = UserDefaults.standard
        let deviceIDKey = "RemotePadDevClientDeviceID"
        let privateKeyKey = "RemotePadDevClientPrivateKey"

        if let deviceIDString = defaults.string(forKey: deviceIDKey),
           let deviceID = UUID(uuidString: deviceIDString),
           let privateKeyString = defaults.string(forKey: privateKeyKey),
           let privateKeyData = Data(base64Encoded: privateKeyString),
           let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData) {
            return DevClientIdentity(deviceID: deviceID, privateKey: privateKey)
        }

        let deviceID = UUID()
        let privateKey = Curve25519.Signing.PrivateKey()
        defaults.set(deviceID.uuidString, forKey: deviceIDKey)
        defaults.set(privateKey.rawRepresentation.base64EncodedString(), forKey: privateKeyKey)
        return DevClientIdentity(deviceID: deviceID, privateKey: privateKey)
    }

    static func reset() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "RemotePadDevClientDeviceID")
        defaults.removeObject(forKey: "RemotePadDevClientPrivateKey")
    }

    func sign(_ data: Data) -> Data {
        (try? privateKey.signature(for: data)) ?? Data()
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
