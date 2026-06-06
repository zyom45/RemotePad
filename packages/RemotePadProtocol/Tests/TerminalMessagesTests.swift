import Foundation
import Testing
@testable import RemotePadProtocol

@Test func terminalCreateRoundTrips() throws {
    let create = TerminalCreate(
        shell: "/bin/zsh",
        cwd: "/Users/nao/Documents/RemotePad",
        cols: 120,
        rows: 36,
        env: ["TERM": "xterm-256color", "LANG": "en_US.UTF-8"]
    )

    let frame = try FrameCodec.decode(
        try FrameCodec.encodeHeader(create, type: .request, channelID: 2, requestID: 10)
    )
    let decoded = try FrameCodec.decodeHeader(TerminalCreate.self, from: frame)

    #expect(decoded == create)
    #expect(frame.channelID == 2)
}

@Test func terminalOutputCarriesPayloadSeparately() throws {
    let output = TerminalOutput(terminalID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    let payload = Data("hello\n".utf8)

    let frame = try FrameCodec.decode(
        try FrameCodec.encodeHeader(output, type: .data, channelID: 2, requestID: 11, payload: payload)
    )
    let decoded = try FrameCodec.decodeHeader(TerminalOutput.self, from: frame)

    #expect(decoded == output)
    #expect(frame.payload == payload)
}

@Test func terminalResizeRoundTrips() throws {
    let resize = TerminalResize(
        terminalID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        cols: 100,
        rows: 30
    )

    let frame = try FrameCodec.decode(
        try FrameCodec.encodeHeader(resize, type: .request, channelID: 2)
    )
    let decoded = try FrameCodec.decodeHeader(TerminalResize.self, from: frame)

    #expect(decoded == resize)
}

@Test func terminalListResultRoundTrips() throws {
    let item = TerminalListItem(
        terminalID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
        title: "zsh - RemotePad",
        shell: "/bin/zsh",
        cwd: "/Users/nao/Documents/RemotePad",
        cols: 100,
        rows: 30,
        state: .running,
        createdAt: Date(timeIntervalSince1970: 1_800_000_000),
        lastActiveAt: Date(timeIntervalSince1970: 1_800_000_100)
    )
    let result = TerminalListResult(terminals: [item])

    let frame = try FrameCodec.decode(
        try FrameCodec.encodeHeader(result, type: .response, channelID: 2)
    )
    let decoded = try FrameCodec.decodeHeader(TerminalListResult.self, from: frame)

    #expect(decoded == result)
    #expect(decoded.terminals.first?.terminalID == item.terminalID)
}

@Test func terminalAttachRoundTrips() throws {
    let attach = TerminalAttach(
        terminalID: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    )

    let frame = try FrameCodec.decode(
        try FrameCodec.encodeHeader(attach, type: .request, channelID: 2, requestID: 20)
    )
    let decoded = try FrameCodec.decodeHeader(TerminalAttach.self, from: frame)

    #expect(decoded == attach)
}

@Test func terminalAttachedRoundTrips() throws {
    let item = TerminalListItem(
        terminalID: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
        title: "zsh - RemotePad",
        shell: "/bin/zsh",
        cwd: "/Users/nao/Documents/RemotePad",
        cols: 100,
        rows: 30,
        state: .running,
        createdAt: Date(timeIntervalSince1970: 1_800_000_000),
        lastActiveAt: Date(timeIntervalSince1970: 1_800_000_100)
    )
    let attached = TerminalAttached(terminal: item)

    let frame = try FrameCodec.decode(
        try FrameCodec.encodeHeader(attached, type: .response, channelID: 2, requestID: 21)
    )
    let decoded = try FrameCodec.decodeHeader(TerminalAttached.self, from: frame)

    #expect(decoded == attached)
}

@Test func terminalCloseRoundTrips() throws {
    let close = TerminalClose(
        terminalID: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!
    )

    let frame = try FrameCodec.decode(
        try FrameCodec.encodeHeader(close, type: .request, channelID: 2, requestID: 30)
    )
    let decoded = try FrameCodec.decodeHeader(TerminalClose.self, from: frame)

    #expect(decoded == close)
}

@Test func terminalClosedRoundTrips() throws {
    let closed = TerminalClosed(
        terminalID: UUID(uuidString: "00000000-0000-0000-0000-000000000007")!,
        reason: "client_requested"
    )

    let frame = try FrameCodec.decode(
        try FrameCodec.encodeHeader(closed, type: .response, channelID: 2, requestID: 31)
    )
    let decoded = try FrameCodec.decodeHeader(TerminalClosed.self, from: frame)

    #expect(decoded == closed)
}
