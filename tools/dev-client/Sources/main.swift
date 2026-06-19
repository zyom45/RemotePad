import Foundation
import CryptoKit
import Network
import RemotePadProtocol

@main
struct RemotePadDevClientCommand {
    static func main() async throws {
        guard CommandLine.arguments.count >= 2, let port = UInt16(CommandLine.arguments[1]) else {
            print("usage: swift run remotepad-dev-client <port> [--attach-first] [--close-after-ready] [--browser-get <local-port> [path]]")
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

    private static func parseMode(arguments: [String]) -> DevClientMode {
        if let index = arguments.firstIndex(of: "--browser-get"),
           arguments.indices.contains(index + 1),
           let port = UInt16(arguments[index + 1]) {
            let path = arguments.indices.contains(index + 2) && !arguments[index + 2].hasPrefix("--")
                ? arguments[index + 2]
                : "/"
            return .browserGet(BrowserTarget(port: port, path: path))
        }

        return arguments.contains("--attach-first") ? .attachFirst : .create
    }
}

enum DevClientMode {
    case create
    case attachFirst
    case browserGet(BrowserTarget)
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
    private var didFinish = false
    private var terminalOutputBuffer = ""
    private var activeTerminalID: UUID?

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

struct DevClientIdentity {
    let deviceID: UUID
    let privateKey: Curve25519.Signing.PrivateKey

    var publicKey: Data {
        privateKey.publicKey.rawRepresentation
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
