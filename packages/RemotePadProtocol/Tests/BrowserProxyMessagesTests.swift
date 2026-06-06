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
