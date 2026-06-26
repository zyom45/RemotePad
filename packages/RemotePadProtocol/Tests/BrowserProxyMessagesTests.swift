import Foundation
import Testing
@testable import RemotePadProtocol

@Test func browserRequestRoundTrips() throws {
    let request = BrowserRequest(
        method: "GET",
        target: BrowserTarget(
            scheme: "http",
            host: "127.0.0.1",
            port: 5173,
            path: "/index.html"
        ),
        headers: ["Accept": "text/html"]
    )

    let frame = try FrameCodec.decode(
        try FrameCodec.encodeHeader(request, type: .request, channelID: 3, requestID: 40)
    )
    let decoded = try FrameCodec.decodeHeader(BrowserRequest.self, from: frame)

    #expect(decoded == request)
    #expect(frame.channelID == 3)
}

@Test func browserResponseCarriesBodyPayload() throws {
    let response = BrowserResponse(
        status: 200,
        headers: ["Content-Type": "text/plain"]
    )
    let body = Data("RemotePad browser proxy".utf8)

    let frame = try FrameCodec.decode(
        try FrameCodec.encodeHeader(response, type: .response, channelID: 3, requestID: 41, payload: body)
    )
    let decoded = try FrameCodec.decodeHeader(BrowserResponse.self, from: frame)

    #expect(decoded == response)
    #expect(frame.payload == body)
}

@Test func browserStreamOpenRoundTrips() throws {
    let message = BrowserStreamOpen(
        streamID: UUID(uuidString: "00000000-0000-0000-0000-000000000123")!,
        target: BrowserTarget(scheme: "tcp", host: "127.0.0.1", port: 5173, path: "")
    )

    let frame = try FrameCodec.decode(
        try FrameCodec.encodeHeader(message, type: .request, channelID: 3, requestID: 42)
    )
    let decoded = try FrameCodec.decodeHeader(BrowserStreamOpen.self, from: frame)

    #expect(decoded == message)
    #expect(decoded.kind == "browser.stream.open")
}

@Test func browserStreamDataCarriesTCPBytes() throws {
    let message = BrowserStreamData(
        streamID: UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
    )
    let bytes = Data("GET / HTTP/1.1\r\n\r\n".utf8)

    let frame = try FrameCodec.decode(
        try FrameCodec.encodeHeader(message, type: .data, channelID: 3, requestID: 43, payload: bytes)
    )
    let decoded = try FrameCodec.decodeHeader(BrowserStreamData.self, from: frame)

    #expect(decoded == message)
    #expect(frame.payload == bytes)
}

@Test func browserStreamCloseRoundTrips() throws {
    let message = BrowserStreamClose(
        streamID: UUID(uuidString: "00000000-0000-0000-0000-000000000123")!,
        reason: "eof"
    )

    let frame = try FrameCodec.decode(
        try FrameCodec.encodeHeader(message, type: .request, channelID: 3, requestID: 44)
    )
    let decoded = try FrameCodec.decodeHeader(BrowserStreamClose.self, from: frame)

    #expect(decoded == message)
}
