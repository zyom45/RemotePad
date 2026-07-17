import Foundation
import RemotePadAgentSupport
import Testing

@Test func auditLoggerAppendsStructuredEvents() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("RemotePadAuditTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("audit.jsonl")
    let logger = try AuditLogger(fileURL: fileURL)
    let deviceID = UUID()

    logger.record(AuditEvent(event: "auth.accepted", deviceID: deviceID, details: ["transport": "e2e-v2"]))

    let line = try String(contentsOf: fileURL, encoding: .utf8)
        .split(separator: "\n")
        .map(String.init)
        .first
    let decoded = try JSONDecoder.remotePadAudit.decode(AuditEvent.self, from: Data((line ?? "").utf8))
    #expect(decoded.event == "auth.accepted")
    #expect(decoded.deviceID == deviceID)
    #expect(decoded.details["transport"] == "e2e-v2")
}

private extension JSONDecoder {
    static var remotePadAudit: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
