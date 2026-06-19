import Foundation

public enum DeviceType: String, Codable, Equatable, Sendable {
    case ipad
    case mac
}

public struct DeviceIdentity: Codable, Equatable, Sendable {
    public var deviceID: UUID
    public var deviceName: String
    public var deviceType: DeviceType
    public var publicKey: Data
    public var createdAt: Date

    public init(
        deviceID: UUID,
        deviceName: String,
        deviceType: DeviceType,
        publicKey: Data,
        createdAt: Date
    ) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.deviceType = deviceType
        self.publicKey = publicKey
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case deviceName = "device_name"
        case deviceType = "device_type"
        case publicKey = "public_key"
        case createdAt = "created_at"
    }
}

public struct Permissions: Codable, Equatable, Sendable {
    public var terminal: Bool
    public var browserProxy: Bool
    public var clipboard: Bool
    public var screen: Bool
    public var audio: Bool
    public var devtools: Bool

    public init(
        terminal: Bool,
        browserProxy: Bool,
        clipboard: Bool,
        screen: Bool,
        audio: Bool,
        devtools: Bool
    ) {
        self.terminal = terminal
        self.browserProxy = browserProxy
        self.clipboard = clipboard
        self.screen = screen
        self.audio = audio
        self.devtools = devtools
    }

    public static let mvpDefault = Permissions(
        terminal: true,
        browserProxy: true,
        clipboard: false,
        screen: false,
        audio: false,
        devtools: true
    )

    enum CodingKeys: String, CodingKey {
        case terminal
        case browserProxy = "browser_proxy"
        case clipboard
        case screen
        case audio
        case devtools
    }
}

public enum ChannelKind: String, Codable, Equatable, Sendable {
    case control
    case terminal
    case browserProxy = "browser_proxy"
    case clipboard
    case devtools
    case screen
    case audio
}

public struct CapabilitySet: Codable, Equatable, Sendable {
    public var channels: [ChannelKind]
    public var protocolVersion: UInt8

    public init(
        channels: [ChannelKind],
        protocolVersion: UInt8 = RemotePadProtocol.currentVersion
    ) {
        self.channels = channels
        self.protocolVersion = protocolVersion
    }

    public static let mvp = CapabilitySet(
        channels: [.control, .terminal, .browserProxy, .devtools]
    )

    enum CodingKeys: String, CodingKey {
        case channels
        case protocolVersion = "protocol_version"
    }
}

public struct PairingStart: Codable, Equatable, Sendable {
    public var kind: String
    public var identity: DeviceIdentity

    public init(identity: DeviceIdentity) {
        self.kind = "pairing.start"
        self.identity = identity
    }
}

public struct PairingChallenge: Codable, Equatable, Sendable {
    public var kind: String
    public var challenge: Data
    public var macIdentity: DeviceIdentity

    public init(challenge: Data, macIdentity: DeviceIdentity) {
        self.kind = "pairing.challenge"
        self.challenge = challenge
        self.macIdentity = macIdentity
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case challenge
        case macIdentity = "mac_identity"
    }
}

public struct PairingResponse: Codable, Equatable, Sendable {
    public var kind: String
    public var signature: Data

    public init(signature: Data) {
        self.kind = "pairing.response"
        self.signature = signature
    }
}

public struct PairingApproved: Codable, Equatable, Sendable {
    public var kind: String
    public var macSignature: Data
    public var permissions: Permissions

    public init(macSignature: Data, permissions: Permissions) {
        self.kind = "pairing.approved"
        self.macSignature = macSignature
        self.permissions = permissions
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case macSignature = "mac_signature"
        case permissions
    }
}

public struct ClientHello: Codable, Equatable, Sendable {
    public var kind: String
    public var deviceID: UUID
    public var nonce: Data
    public var supportedProtocols: [UInt8]
    public var publicKey: Data?

    public init(
        deviceID: UUID,
        nonce: Data,
        supportedProtocols: [UInt8] = [RemotePadProtocol.currentVersion],
        publicKey: Data? = nil
    ) {
        self.kind = "client.hello"
        self.deviceID = deviceID
        self.nonce = nonce
        self.supportedProtocols = supportedProtocols
        self.publicKey = publicKey
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case deviceID = "device_id"
        case nonce
        case supportedProtocols = "supported_protocols"
        case publicKey = "public_key"
    }
}

public struct ServerHello: Codable, Equatable, Sendable {
    public var kind: String
    public var deviceID: UUID
    public var nonce: Data
    public var capabilities: CapabilitySet

    public init(
        deviceID: UUID,
        nonce: Data,
        capabilities: CapabilitySet
    ) {
        self.kind = "server.hello"
        self.deviceID = deviceID
        self.nonce = nonce
        self.capabilities = capabilities
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case deviceID = "device_id"
        case nonce
        case capabilities
    }
}

public struct AuthProof: Codable, Equatable, Sendable {
    public var kind: String
    public var signature: Data

    public init(signature: Data) {
        self.kind = "auth.proof"
        self.signature = signature
    }
}

public struct AuthResult: Codable, Equatable, Sendable {
    public var kind: String
    public var accepted: Bool
    public var sessionID: UUID?
    public var permissions: Permissions?
    public var reason: String?

    public init(
        accepted: Bool,
        sessionID: UUID?,
        permissions: Permissions?,
        reason: String? = nil
    ) {
        self.kind = "auth.result"
        self.accepted = accepted
        self.sessionID = sessionID
        self.permissions = permissions
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case accepted
        case sessionID = "session_id"
        case permissions
        case reason
    }
}

public struct SessionStatus: Codable, Equatable, Sendable {
    public var kind: String
    public var sessionID: UUID
    public var connectedAt: Date
    public var permissions: Permissions

    public init(
        sessionID: UUID,
        connectedAt: Date,
        permissions: Permissions
    ) {
        self.kind = "session.status"
        self.sessionID = sessionID
        self.connectedAt = connectedAt
        self.permissions = permissions
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case sessionID = "session_id"
        case connectedAt = "connected_at"
        case permissions
    }
}

public struct ProtocolErrorMessage: Codable, Equatable, Sendable {
    public var kind: String
    public var code: String
    public var message: String
    public var requestID: UInt32?
    public var supportedProtocols: [UInt8]?
    public var minimumSupportedProtocol: UInt8?

    public init(
        code: String,
        message: String,
        requestID: UInt32? = nil,
        supportedProtocols: [UInt8]? = nil,
        minimumSupportedProtocol: UInt8? = nil
    ) {
        self.kind = "error"
        self.code = code
        self.message = message
        self.requestID = requestID
        self.supportedProtocols = supportedProtocols
        self.minimumSupportedProtocol = minimumSupportedProtocol
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case code
        case message
        case requestID = "request_id"
        case supportedProtocols = "supported_protocols"
        case minimumSupportedProtocol = "minimum_supported_protocol"
    }
}

public enum AuthTranscript {
    public static func make(
        clientDeviceID: UUID,
        clientNonce: Data,
        serverDeviceID: UUID,
        serverNonce: Data,
        protocolVersion: UInt8 = RemotePadProtocol.currentVersion
    ) -> Data {
        var data = Data("RemotePad auth v1".utf8)
        data.append(protocolVersion)
        data.appendUUID(clientDeviceID)
        data.appendLengthPrefixed(clientNonce)
        data.appendUUID(serverDeviceID)
        data.appendLengthPrefixed(serverNonce)
        return data
    }
}

private extension Data {
    mutating func appendUUID(_ uuid: UUID) {
        var value = uuid.uuid
        Swift.withUnsafeBytes(of: &value) { rawBuffer in
            append(rawBuffer.bindMemory(to: UInt8.self))
        }
    }

    mutating func appendLengthPrefixed(_ value: Data) {
        appendUInt32(UInt32(value.count))
        append(value)
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }
}
