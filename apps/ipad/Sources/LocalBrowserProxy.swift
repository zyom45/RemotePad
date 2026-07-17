import CryptoKit
import Foundation
import Network
import RemotePadProtocol
import RemotePadSecurity

struct AppIdentity: Sendable {
    let deviceID: UUID
    let privateKey: Curve25519.Signing.PrivateKey

    var publicKey: Data {
        privateKey.publicKey.rawRepresentation
    }

    var fingerprint: String {
        SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined()
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

    static func loadOrCreate() -> AppIdentity {
        do {
            let identity = try DeviceKeyIdentity.loadOrCreate(
                service: "com.remotepad.ipad.identity",
                legacyDefaults: .standard,
                legacyDeviceIDKey: "RemotePadAppDeviceID",
                legacyPrivateKeyKey: "RemotePadAppPrivateKey"
            )
            return AppIdentity(deviceID: identity.deviceID, privateKey: identity.privateKey)
        } catch {
            fatalError("RemotePad could not load its Keychain identity: \(error)")
        }
    }

    func sign(_ data: Data) -> Data {
        (try? privateKey.signature(for: data)) ?? Data()
    }

    func pinMac(deviceID: UUID, publicKey: Data) throws {
        guard (try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey)) != nil else {
            throw RemotePadSecurityError.invalidIdentity
        }
        try KeychainDataStore(service: "com.remotepad.ipad.paired-macs")
            .set(publicKey, for: deviceID.uuidString)
    }

    func pinnedMacPublicKey(deviceID: UUID) -> Data? {
        try? KeychainDataStore(service: "com.remotepad.ipad.paired-macs")
            .data(for: deviceID.uuidString)
    }

    func verifiesServerHello(_ hello: ServerHello, clientNonce: Data, clientKeyAgreementPublicKey: Data) -> Bool {
        guard pinnedMacPublicKey(deviceID: hello.deviceID) == hello.identityPublicKey,
              let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: hello.identityPublicKey) else {
            return false
        }
        let transcript = ServerHelloTranscript.make(
            clientDeviceID: deviceID,
            clientNonce: clientNonce,
            clientKeyAgreementPublicKey: clientKeyAgreementPublicKey,
            serverDeviceID: hello.deviceID,
            serverNonce: hello.nonce,
            serverIdentityPublicKey: hello.identityPublicKey,
            serverKeyAgreementPublicKey: hello.keyAgreementPublicKey
        )
        return publicKey.isValidSignature(hello.signature, for: transcript)
    }
}

final class LocalBrowserProxy: @unchecked Sendable {
    private let agentHost: String
    private let agentPort: UInt16
    private let listenPort: UInt16
    private let targetPort: UInt16
    private let identity: AppIdentity
    private let onStatus: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "RemotePad.iPad.LocalBrowserProxy")
    private let listener: NWListener
    private var connections: [UUID: LocalBrowserProxyConnection] = [:]

    init(
        agentHost: String,
        agentPort: UInt16,
        listenPort: UInt16,
        targetPort: UInt16,
        identity: AppIdentity,
        onStatus: @escaping @Sendable (String) -> Void
    ) throws {
        self.agentHost = agentHost
        self.agentPort = agentPort
        self.listenPort = listenPort
        self.targetPort = targetPort
        self.identity = identity
        self.onStatus = onStatus

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
                agentHost: self.agentHost,
                agentPort: self.agentPort,
                targetPort: self.targetPort,
                identity: self.identity,
                queue: self.queue,
                onStatus: self.onStatus,
                onClose: { [weak self] id in
                    self?.connections[id] = nil
                }
            )
            self.connections[connection.id] = connection
            connection.start()
        }
        listener.stateUpdateHandler = { [onStatus] state in
            switch state {
            case .ready:
                onStatus("Listening")
            case .failed(let error):
                onStatus("Listener failed: \(error)")
            default:
                break
            }
        }
        listener.start(queue: queue)
    }

    func stop() {
        for connection in connections.values {
            connection.close()
        }
        connections.removeAll()
        listener.cancel()
    }
}

final class LocalBrowserProxyConnection: @unchecked Sendable {
    let id = UUID()

    private let localConnection: NWConnection
    private let agentConnection: NWConnection
    private let targetPort: UInt16
    private let identity: AppIdentity
    private let queue: DispatchQueue
    private let onStatus: @Sendable (String) -> Void
    private let onClose: (UUID) -> Void
    private let decoder = FrameStreamDecoder()
    private let streamID = UUID()
    private let keyExchange = SessionKeyExchange()

    private var clientNonce: Data?
    private var serverDeviceID: UUID?
    private var serverNonce: Data?
    private var serverKeyAgreementPublicKey: Data?
    private var pendingSecureSession: SecureSession?
    private var secureSession: SecureSession?
    private var didOpenStream = false
    private var isClosed = false
    private var pendingLocalData: [Data] = []

    init(
        localConnection: NWConnection,
        agentHost: String,
        agentPort: UInt16,
        targetPort: UInt16,
        identity: AppIdentity,
        queue: DispatchQueue,
        onStatus: @escaping @Sendable (String) -> Void,
        onClose: @escaping (UUID) -> Void
    ) {
        self.localConnection = localConnection
        self.agentConnection = NWConnection(
            host: NWEndpoint.Host(agentHost),
            port: NWEndpoint.Port(rawValue: agentPort)!,
            using: .tcp
        )
        self.targetPort = targetPort
        self.identity = identity
        self.queue = queue
        self.onStatus = onStatus
        self.onClose = onClose
    }

    func start() {
        localConnection.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                self?.close()
            }
        }
        agentConnection.stateUpdateHandler = { [weak self] state in
            self?.handleAgentState(state)
        }

        receiveLocal()
        localConnection.start(queue: queue)
        agentConnection.start(queue: queue)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        localConnection.cancel()
        agentConnection.cancel()
        onClose(id)
    }

    private func handleAgentState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            sendClientHello()
            receiveAgent()
        case .failed(let error):
            onStatus("Agent connection failed: \(error)")
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
            publicKey: identity.publicKey,
            keyAgreementPublicKey: keyExchange.publicKey
        )
        sendToAgent(hello, type: .request, channelID: 1, requestID: 1)
    }

    private func receiveAgent() {
        agentConnection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.onStatus("Agent receive failed: \(error)")
                self.close()
                return
            }

            if let data, !data.isEmpty {
                do {
                    let frames = try self.decoder.append(data)
                    for receivedFrame in frames {
                        let frame = try self.secureSession?.open(frame: receivedFrame) ?? receivedFrame
                        try self.handleAgentFrame(frame)
                    }
                } catch {
                    self.onStatus("Protocol error: \(error)")
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
            guard let clientNonce,
                  identity.verifiesServerHello(
                    hello,
                    clientNonce: clientNonce,
                    clientKeyAgreementPublicKey: keyExchange.publicKey
                  ) else {
                onStatus("Untrusted Mac identity")
                close()
                return
            }
            serverDeviceID = hello.deviceID
            serverNonce = hello.nonce
            serverKeyAgreementPublicKey = hello.keyAgreementPublicKey
            pendingSecureSession = try SecureSession(
                privateKey: keyExchange.privateKey,
                remotePublicKey: hello.keyAgreementPublicKey,
                clientNonce: clientNonce,
                serverNonce: hello.nonce,
                role: .client
            )
            sendAuthProof()
        case "auth.result":
            let result = try FrameCodec.decodeHeader(AuthResult.self, from: frame)
            guard result.accepted else {
                onStatus("Auth rejected: \(result.reason ?? "unknown")")
                close()
                return
            }
            secureSession = pendingSecureSession
            pendingSecureSession = nil
            openBrowserStream()
        case "browser.stream.data":
            sendToLocal(frame.payload)
        case "browser.stream.close":
            close()
        case "error":
            let error = try FrameCodec.decodeHeader(ProtocolErrorMessage.self, from: frame)
            onStatus("Remote error: \(error.code)")
            close()
        default:
            break
        }
    }

    private func sendAuthProof() {
        guard let clientNonce, let serverDeviceID, let serverNonce, let serverKeyAgreementPublicKey else {
            close()
            return
        }
        let transcript = AuthTranscript.make(
            clientDeviceID: identity.deviceID,
            clientNonce: clientNonce,
            serverDeviceID: serverDeviceID,
            serverNonce: serverNonce,
            clientKeyAgreementPublicKey: keyExchange.publicKey,
            serverKeyAgreementPublicKey: serverKeyAgreementPublicKey
        )
        sendToAgent(
            AuthProof(signature: identity.sign(transcript)),
            type: .request,
            channelID: 1,
            requestID: 2
        )
    }

    private func openBrowserStream() {
        guard !didOpenStream else { return }
        didOpenStream = true
        sendToAgent(
            BrowserStreamOpen(
                streamID: streamID,
                target: BrowserTarget(scheme: "tcp", host: "127.0.0.1", port: targetPort, path: "")
            ),
            type: .request,
            channelID: 3,
            requestID: 3
        )
        let pending = pendingLocalData
        pendingLocalData.removeAll()
        for data in pending {
            sendBrowserData(data)
        }
    }

    private func receiveLocal() {
        localConnection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.onStatus("Browser receive failed: \(error)")
                self.close()
                return
            }

            if let data, !data.isEmpty {
                if self.didOpenStream {
                    self.sendBrowserData(data)
                } else {
                    self.pendingLocalData.append(data)
                }
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
            if error != nil {
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
            let plaintext = try FrameCodec.decode(FrameCodec.encodeHeader(
                header,
                type: type,
                channelID: channelID,
                requestID: requestID,
                payload: payload
            ))
            let data = try secureSession?.seal(frame: plaintext) ?? FrameCodec.encode(plaintext)
            agentConnection.send(content: data, completion: .contentProcessed { [weak self] error in
                if error != nil {
                    self?.close()
                }
            })
        } catch {
            onStatus("Encode failed: \(error)")
            close()
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
