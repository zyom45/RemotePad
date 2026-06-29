import Foundation

struct TerminalTextBuffer {
    private var lines: [String] = []
    private var currentLine = ""
    private var parserState = ParserState.ground
    private let maxLines: Int

    init(maxLines: Int = 2_000) {
        self.maxLines = maxLines
    }

    var text: String {
        (lines + [currentLine]).joined(separator: "\n")
    }

    mutating func append(_ string: String) {
        for scalar in string.unicodeScalars {
            consume(scalar)
        }
        trimIfNeeded()
    }

    mutating func clear() {
        lines = []
        currentLine = ""
        parserState = .ground
    }

    private mutating func consume(_ scalar: UnicodeScalar) {
        switch parserState {
        case .ground:
            consumeGround(scalar)
        case .escape:
            consumeEscape(scalar)
        case .controlSequence:
            consumeControlSequence(scalar)
        case .operatingSystemCommand:
            consumeOperatingSystemCommand(scalar)
        case .operatingSystemCommandEscape:
            parserState = scalar == "\\" ? .ground : .operatingSystemCommand
        }
    }

    private mutating func consumeGround(_ scalar: UnicodeScalar) {
        switch scalar.value {
        case 0x08:
            if !currentLine.isEmpty {
                currentLine.removeLast()
            }
        case 0x0A:
            lines.append(currentLine)
            currentLine = ""
        case 0x0D:
            currentLine = ""
        case 0x1B:
            parserState = .escape
        case 0x00...0x1F, 0x7F:
            break
        default:
            currentLine.unicodeScalars.append(scalar)
        }
    }

    private mutating func consumeEscape(_ scalar: UnicodeScalar) {
        switch scalar {
        case "[":
            parserState = .controlSequence
        case "]":
            parserState = .operatingSystemCommand
        case "c":
            clear()
        default:
            parserState = .ground
        }
    }

    private mutating func consumeControlSequence(_ scalar: UnicodeScalar) {
        guard scalar.value <= UInt8.max else {
            parserState = .ground
            return
        }
        let byte = UInt8(scalar.value)

        if byte >= 0x40 && byte <= 0x7E {
            handleControlSequenceFinal(byte)
            parserState = .ground
        }
    }

    private mutating func consumeOperatingSystemCommand(_ scalar: UnicodeScalar) {
        switch scalar.value {
        case 0x07:
            parserState = .ground
        case 0x1B:
            parserState = .operatingSystemCommandEscape
        default:
            break
        }
    }

    private mutating func handleControlSequenceFinal(_ byte: UInt8) {
        switch byte {
        case CharacterCode.eraseInDisplay:
            clear()
        case CharacterCode.eraseInLine:
            currentLine = ""
        default:
            break
        }
    }

    private mutating func trimIfNeeded() {
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
    }
}

private enum ParserState {
    case ground
    case escape
    case controlSequence
    case operatingSystemCommand
    case operatingSystemCommandEscape
}

private enum CharacterCode {
    static let eraseInDisplay = UInt8(ascii: "J")
    static let eraseInLine = UInt8(ascii: "K")
}
