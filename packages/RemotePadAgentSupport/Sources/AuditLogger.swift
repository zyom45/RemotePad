import Foundation

public struct AuditEvent: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let event: String
    public let connectionID: UUID?
    public let deviceID: UUID?
    public let details: [String: String]

    public init(
        timestamp: Date = Date(),
        event: String,
        connectionID: UUID? = nil,
        deviceID: UUID? = nil,
        details: [String: String] = [:]
    ) {
        self.timestamp = timestamp
        self.event = event
        self.connectionID = connectionID
        self.deviceID = deviceID
        self.details = details
    }

    enum CodingKeys: String, CodingKey {
        case timestamp
        case event
        case connectionID = "connection_id"
        case deviceID = "device_id"
        case details
    }
}

public final class AuditLogger: @unchecked Sendable {
    public let fileURL: URL

    private let lock = NSLock()
    private let encoder: JSONEncoder

    public init(fileURL: URL = AuditLogger.defaultFileURL()) throws {
        self.fileURL = fileURL
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601

        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: fileURL.path
        )
    }

    public func record(_ event: AuditEvent) {
        lock.lock()
        defer { lock.unlock() }

        do {
            var line = try encoder.encode(event)
            line.append(0x0a)
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            fputs("RemotePad audit log write failed: \(error)\n", stderr)
        }
    }

    public static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("RemotePad/audit.jsonl")
    }
}
