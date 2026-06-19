import Foundation

public enum RemotePadProtocol {
    public static let currentVersion: UInt8 = 1
    public static let magic = Data([0x52, 0x50, 0x41, 0x44]) // RPAD
}

public enum FrameCodecError: Error, Equatable {
    case invalidMagic
    case unsupportedVersion(UInt8)
    case unknownFrameType(UInt8)
    case unsupportedCompression
    case headerTooLarge(Int)
    case payloadTooLarge(Int)
    case invalidHeader
    case incompleteFrame
}

public enum FrameType: UInt8, Codable, Equatable, Sendable {
    case control = 0x01
    case openChannel = 0x02
    case closeChannel = 0x03
    case data = 0x04
    case request = 0x05
    case response = 0x06
    case error = 0x07
    case ping = 0x08
    case pong = 0x09
}

public struct FrameFlags: OptionSet, Equatable, Sendable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let compressed = FrameFlags(rawValue: 1 << 0)
    public static let acknowledgement = FrameFlags(rawValue: 1 << 1)
    public static let error = FrameFlags(rawValue: 1 << 2)
}

public struct Frame: Equatable, Sendable {
    public static let fixedHeaderLength = 24
    public static let maxHeaderLength = 64 * 1024
    public static let maxPayloadLength = 16 * 1024 * 1024

    public var version: UInt8
    public var type: FrameType
    public var flags: FrameFlags
    public var channelID: UInt32
    public var requestID: UInt32
    public var header: Data
    public var payload: Data

    public init(
        version: UInt8 = RemotePadProtocol.currentVersion,
        type: FrameType,
        flags: FrameFlags = [],
        channelID: UInt32,
        requestID: UInt32 = 0,
        header: Data = Data(),
        payload: Data = Data()
    ) {
        self.version = version
        self.type = type
        self.flags = flags
        self.channelID = channelID
        self.requestID = requestID
        self.header = header
        self.payload = payload
    }
}

public struct JSONFrame<Header: Codable>: Equatable where Header: Equatable {
    public var frame: Frame
    public var header: Header

    public init(frame: Frame, header: Header) {
        self.frame = frame
        self.header = header
    }
}

public enum FrameCodec {
    public static func encode(_ frame: Frame) throws -> Data {
        guard frame.header.count <= Frame.maxHeaderLength else {
            throw FrameCodecError.headerTooLarge(frame.header.count)
        }
        guard frame.payload.count <= Frame.maxPayloadLength else {
            throw FrameCodecError.payloadTooLarge(frame.payload.count)
        }

        var data = Data()
        data.reserveCapacity(Frame.fixedHeaderLength + frame.header.count + frame.payload.count)
        data.append(RemotePadProtocol.magic)
        data.append(frame.version)
        data.append(frame.type.rawValue)
        data.appendUInt16(frame.flags.rawValue)
        data.appendUInt32(frame.channelID)
        data.appendUInt32(frame.requestID)
        data.appendUInt32(UInt32(frame.header.count))
        data.appendUInt32(UInt32(frame.payload.count))
        data.append(frame.header)
        data.append(frame.payload)
        return data
    }

    public static func decode(_ data: Data) throws -> Frame {
        guard data.count >= Frame.fixedHeaderLength else {
            throw FrameCodecError.incompleteFrame
        }

        var cursor = DataCursor(data: data)
        let magic = try cursor.readData(count: 4)
        guard magic == RemotePadProtocol.magic else {
            throw FrameCodecError.invalidMagic
        }

        let version = try cursor.readUInt8()
        guard version == RemotePadProtocol.currentVersion else {
            throw FrameCodecError.unsupportedVersion(version)
        }

        let typeRaw = try cursor.readUInt8()
        guard let type = FrameType(rawValue: typeRaw) else {
            throw FrameCodecError.unknownFrameType(typeRaw)
        }

        let flags = FrameFlags(rawValue: try cursor.readUInt16())
        guard !flags.contains(.compressed) else {
            throw FrameCodecError.unsupportedCompression
        }

        let channelID = try cursor.readUInt32()
        let requestID = try cursor.readUInt32()
        let headerLength = Int(try cursor.readUInt32())
        let payloadLength = Int(try cursor.readUInt32())

        guard headerLength <= Frame.maxHeaderLength else {
            throw FrameCodecError.headerTooLarge(headerLength)
        }
        guard payloadLength <= Frame.maxPayloadLength else {
            throw FrameCodecError.payloadTooLarge(payloadLength)
        }
        guard data.count >= Frame.fixedHeaderLength + headerLength + payloadLength else {
            throw FrameCodecError.incompleteFrame
        }

        let header = try cursor.readData(count: headerLength)
        let payload = try cursor.readData(count: payloadLength)

        return Frame(
            version: version,
            type: type,
            flags: flags,
            channelID: channelID,
            requestID: requestID,
            header: header,
            payload: payload
        )
    }

    public static func encodeHeader<Header: Encodable>(
        _ header: Header,
        type: FrameType,
        flags: FrameFlags = [],
        channelID: UInt32,
        requestID: UInt32 = 0,
        payload: Data = Data(),
        encoder: JSONEncoder = .remotePad
    ) throws -> Data {
        let headerData = try encoder.encode(header)
        return try encode(
            Frame(
                type: type,
                flags: flags,
                channelID: channelID,
                requestID: requestID,
                header: headerData,
                payload: payload
            )
        )
    }

    public static func decodeHeader<Header: Decodable>(
        _ type: Header.Type,
        from frame: Frame,
        decoder: JSONDecoder = .remotePad
    ) throws -> Header {
        guard !frame.header.isEmpty else {
            throw FrameCodecError.invalidHeader
        }
        return try decoder.decode(Header.self, from: frame.header)
    }
}

public final class FrameStreamDecoder {
    private var buffer = Data()

    public init() {}

    public func append(_ data: Data) throws -> [Frame] {
        buffer.append(data)

        var frames: [Frame] = []
        while let frameLength = try nextFrameLength() {
            let frameData = buffer.prefix(frameLength)
            frames.append(try FrameCodec.decode(Data(frameData)))
            buffer.removeFirst(frameLength)
        }

        return frames
    }

    public func reset() {
        buffer.removeAll(keepingCapacity: true)
    }

    private func nextFrameLength() throws -> Int? {
        guard buffer.count >= Frame.fixedHeaderLength else {
            return nil
        }

        guard buffer.prefix(4) == RemotePadProtocol.magic else {
            throw FrameCodecError.invalidMagic
        }

        let headerLength = Int(buffer.readUInt32(at: 16))
        let payloadLength = Int(buffer.readUInt32(at: 20))

        guard headerLength <= Frame.maxHeaderLength else {
            throw FrameCodecError.headerTooLarge(headerLength)
        }
        guard payloadLength <= Frame.maxPayloadLength else {
            throw FrameCodecError.payloadTooLarge(payloadLength)
        }

        let frameLength = Frame.fixedHeaderLength + headerLength + payloadLength
        return buffer.count >= frameLength ? frameLength : nil
    }
}

public struct MessageHeader: Codable, Equatable, Sendable {
    public var kind: String

    public init(kind: String) {
        self.kind = kind
    }
}

extension JSONEncoder {
    public static var remotePad: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    public static var remotePad: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private struct DataCursor {
    private let data: Data
    private var offset = 0

    init(data: Data) {
        self.data = data
    }

    mutating func readUInt8() throws -> UInt8 {
        guard offset < data.count else {
            throw FrameCodecError.incompleteFrame
        }
        defer { offset += 1 }
        return data[data.index(data.startIndex, offsetBy: offset)]
    }

    mutating func readUInt16() throws -> UInt16 {
        let bytes = try readData(count: 2)
        return UInt16(bytes[bytes.startIndex]) << 8
            | UInt16(bytes[bytes.index(bytes.startIndex, offsetBy: 1)])
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try readData(count: 4)
        return UInt32(bytes[bytes.startIndex]) << 24
            | UInt32(bytes[bytes.index(bytes.startIndex, offsetBy: 1)]) << 16
            | UInt32(bytes[bytes.index(bytes.startIndex, offsetBy: 2)]) << 8
            | UInt32(bytes[bytes.index(bytes.startIndex, offsetBy: 3)])
    }

    mutating func readData(count: Int) throws -> Data {
        guard offset + count <= data.count else {
            throw FrameCodecError.incompleteFrame
        }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    func readUInt32(at offset: Int) -> UInt32 {
        let first = index(startIndex, offsetBy: offset)
        let second = index(first, offsetBy: 1)
        let third = index(first, offsetBy: 2)
        let fourth = index(first, offsetBy: 3)
        return UInt32(self[first]) << 24
            | UInt32(self[second]) << 16
            | UInt32(self[third]) << 8
            | UInt32(self[fourth])
    }
}
