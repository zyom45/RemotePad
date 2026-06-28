import Foundation
import Network
import RemotePadProtocol

struct PairingClientResult: Sendable {
    var status: String
    var deviceID: UUID
    var reason: String?
}

final class PairingClient: @unchecked Sendable {
    private let agentHost: String
    private let agentPort: UInt16
    private let identity: AppIdentity
    private let deviceName: String
    private let queue = DispatchQueue(label: "RemotePad.iPad.PairingClient")
    private let decoder = FrameStreamDecoder()

    private var connection: NWConnection?
    private var pairingIdentity: DeviceIdentity?
    private var macDeviceID: UUID?
    private var challenge: Data?
    private var continuation: CheckedContinuation<PairingClientResult, Error>?

    init(agentHost: String, agentPort: UInt16, identity: AppIdentity, deviceName: String) {
        self.agentHost = agentHost
        self.agentPort = agentPort
        self.identity = identity
        self.deviceName = deviceName
    }

    func run() async throws -> PairingClientResult {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
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
        }
    }

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            sendPairingStart()
            receive()
        case .failed(let error):
            finish(throwing: error)
        case .cancelled:
            break
        default:
            break
        }
    }

    private func sendPairingStart() {
        let pairingIdentity = identity.deviceIdentity(deviceName: deviceName)
        self.pairingIdentity = pairingIdentity
        send(
            PairingStart(identity: pairingIdentity),
            type: .request,
            channelID: 1,
            requestID: 1
        )
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
                self.finish(throwing: PairingClientError.connectionClosed)
            } else {
                self.receive()
            }
        }
    }

    private func handleFrame(_ frame: Frame) throws {
        let header = try FrameCodec.decodeHeader(MessageHeader.self, from: frame)
        switch header.kind {
        case "pairing.challenge":
            let message = try FrameCodec.decodeHeader(PairingChallenge.self, from: frame)
            challenge = message.challenge
            macDeviceID = message.macIdentity.deviceID
            sendPairingResponse()
        case "pairing.result":
            let result = try FrameCodec.decodeHeader(PairingResult.self, from: frame)
            finish(returning: PairingClientResult(status: result.status, deviceID: result.deviceID, reason: result.reason))
        case "error":
            let error = try FrameCodec.decodeHeader(ProtocolErrorMessage.self, from: frame)
            finish(throwing: PairingClientError.remote(error.code))
        default:
            break
        }
    }

    private func sendPairingResponse() {
        guard let pairingIdentity, let macDeviceID, let challenge else {
            finish(throwing: PairingClientError.missingChallenge)
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

    private func finish(returning result: PairingClientResult) {
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

enum PairingClientError: Error {
    case connectionClosed
    case missingChallenge
    case remote(String)
}
