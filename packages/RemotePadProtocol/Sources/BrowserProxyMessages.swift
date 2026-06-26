import Foundation

public struct BrowserTarget: Codable, Equatable, Sendable {
    public var scheme: String
    public var host: String
    public var port: UInt16
    public var path: String

    public init(
        scheme: String = "http",
        host: String = "127.0.0.1",
        port: UInt16,
        path: String = "/"
    ) {
        self.scheme = scheme
        self.host = host
        self.port = port
        self.path = path
    }
}

public struct BrowserRequest: Codable, Equatable, Sendable {
    public var kind: String
    public var method: String
    public var target: BrowserTarget
    public var headers: [String: String]

    public init(
        method: String = "GET",
        target: BrowserTarget,
        headers: [String: String] = [:]
    ) {
        self.kind = "browser.request"
        self.method = method
        self.target = target
        self.headers = headers
    }
}

public struct BrowserResponse: Codable, Equatable, Sendable {
    public var kind: String
    public var status: Int
    public var headers: [String: String]

    public init(status: Int, headers: [String: String] = [:]) {
        self.kind = "browser.response"
        self.status = status
        self.headers = headers
    }
}

public struct BrowserStreamOpen: Codable, Equatable, Sendable {
    public var kind: String
    public var streamID: UUID
    public var target: BrowserTarget

    public init(streamID: UUID, target: BrowserTarget) {
        self.kind = "browser.stream.open"
        self.streamID = streamID
        self.target = target
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case streamID = "stream_id"
        case target
    }
}

public struct BrowserStreamData: Codable, Equatable, Sendable {
    public var kind: String
    public var streamID: UUID

    public init(streamID: UUID) {
        self.kind = "browser.stream.data"
        self.streamID = streamID
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case streamID = "stream_id"
    }
}

public struct BrowserStreamClose: Codable, Equatable, Sendable {
    public var kind: String
    public var streamID: UUID
    public var reason: String?

    public init(streamID: UUID, reason: String? = nil) {
        self.kind = "browser.stream.close"
        self.streamID = streamID
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case streamID = "stream_id"
        case reason
    }
}
