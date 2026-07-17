import Testing
import Foundation
@testable import RemotePadProtocol

@Test func exposesCurrentVersion() {
    #expect(RemotePadProtocol.currentVersion == 2)
}

@Test func encodesAndDecodesFrame() throws {
    let frame = Frame(
        type: .request,
        flags: [.acknowledgement],
        channelID: 42,
        requestID: 7,
        header: Data(#"{"kind":"terminal.create"}"#.utf8),
        payload: Data("hello".utf8)
    )

    let encoded = try FrameCodec.encode(frame)
    let decoded = try FrameCodec.decode(encoded)

    #expect(encoded.count == Frame.fixedHeaderLength + frame.header.count + frame.payload.count)
    #expect(decoded == frame)
}

@Test func encodesAndDecodesJSONHeader() throws {
    let header = TerminalCreateHeader(
        kind: "terminal.create",
        shell: "/bin/zsh",
        cwd: "/Users/nao/Documents/RemotePad",
        cols: 120,
        rows: 36,
        env: ["TERM": "xterm-256color"]
    )

    let encoded = try FrameCodec.encodeHeader(
        header,
        type: .request,
        channelID: 2,
        requestID: 99
    )
    let frame = try FrameCodec.decode(encoded)
    let decoded = try FrameCodec.decodeHeader(TerminalCreateHeader.self, from: frame)

    #expect(frame.type == .request)
    #expect(frame.channelID == 2)
    #expect(frame.requestID == 99)
    #expect(decoded == header)
}

@Test func streamDecoderWaitsForCompleteFrame() throws {
    let frame = Frame(
        type: .data,
        channelID: 2,
        header: Data(#"{"kind":"terminal.output"}"#.utf8),
        payload: Data("partial terminal output".utf8)
    )
    let encoded = try FrameCodec.encode(frame)
    let firstChunk = encoded.prefix(10)
    let secondChunk = encoded.dropFirst(10)
    let decoder = FrameStreamDecoder()

    let incomplete = try decoder.append(Data(firstChunk))
    #expect(incomplete.isEmpty)

    let complete = try decoder.append(Data(secondChunk))
    #expect(complete == [frame])
}

@Test func streamDecoderReturnsMultipleFrames() throws {
    let first = Frame(type: .ping, channelID: 1, requestID: 1)
    let second = Frame(
        type: .data,
        channelID: 2,
        requestID: 2,
        header: Data(#"{"kind":"terminal.input"}"#.utf8),
        payload: Data("ls\n".utf8)
    )
    var encoded = Data()
    encoded.append(try FrameCodec.encode(first))
    encoded.append(try FrameCodec.encode(second))

    let decoder = FrameStreamDecoder()
    let frames = try decoder.append(encoded)

    #expect(frames == [first, second])
}

@Test func rejectsInvalidMagic() throws {
    var encoded = try FrameCodec.encode(Frame(type: .ping, channelID: 1))
    encoded[0] = 0x00

    #expect(throws: FrameCodecError.invalidMagic) {
        _ = try FrameCodec.decode(encoded)
    }
}

@Test func rejectsUnsupportedVersion() throws {
    var encoded = try FrameCodec.encode(Frame(type: .ping, channelID: 1))
    encoded[4] = 0xff

    #expect(throws: FrameCodecError.unsupportedVersion(0xff)) {
        _ = try FrameCodec.decode(encoded)
    }
}

@Test func rejectsCompressedFrameBeforeNegotiation() throws {
    let encoded = try FrameCodec.encode(
        Frame(
            type: .data,
            flags: [.compressed],
            channelID: 2,
            header: Data(#"{"kind":"terminal.output"}"#.utf8),
            payload: Data([0x01, 0x02])
        )
    )

    #expect(throws: FrameCodecError.unsupportedCompression) {
        _ = try FrameCodec.decode(encoded)
    }
}

private struct TerminalCreateHeader: Codable, Equatable {
    var kind: String
    var shell: String
    var cwd: String
    var cols: Int
    var rows: Int
    var env: [String: String]
}
