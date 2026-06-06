import Foundation

public enum TerminalState: String, Codable, Equatable, Sendable {
    case running
    case exited
}

public struct TerminalCreate: Codable, Equatable, Sendable {
    public var kind: String
    public var shell: String
    public var cwd: String?
    public var cols: UInt16
    public var rows: UInt16
    public var env: [String: String]

    public init(
        shell: String = "/bin/zsh",
        cwd: String? = nil,
        cols: UInt16,
        rows: UInt16,
        env: [String: String] = ["TERM": "xterm-256color"]
    ) {
        self.kind = "terminal.create"
        self.shell = shell
        self.cwd = cwd
        self.cols = cols
        self.rows = rows
        self.env = env
    }
}

public struct TerminalCreated: Codable, Equatable, Sendable {
    public var kind: String
    public var terminalID: UUID
    public var shell: String
    public var cwd: String?
    public var cols: UInt16
    public var rows: UInt16
    public var state: TerminalState

    public init(
        terminalID: UUID,
        shell: String,
        cwd: String?,
        cols: UInt16,
        rows: UInt16,
        state: TerminalState = .running
    ) {
        self.kind = "terminal.created"
        self.terminalID = terminalID
        self.shell = shell
        self.cwd = cwd
        self.cols = cols
        self.rows = rows
        self.state = state
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case terminalID = "terminal_id"
        case shell
        case cwd
        case cols
        case rows
        case state
    }
}

public struct TerminalOutput: Codable, Equatable, Sendable {
    public var kind: String
    public var terminalID: UUID
    public var encoding: String

    public init(terminalID: UUID, encoding: String = "utf8") {
        self.kind = "terminal.output"
        self.terminalID = terminalID
        self.encoding = encoding
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case terminalID = "terminal_id"
        case encoding
    }
}

public struct TerminalInput: Codable, Equatable, Sendable {
    public var kind: String
    public var terminalID: UUID

    public init(terminalID: UUID) {
        self.kind = "terminal.input"
        self.terminalID = terminalID
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case terminalID = "terminal_id"
    }
}

public struct TerminalResize: Codable, Equatable, Sendable {
    public var kind: String
    public var terminalID: UUID
    public var cols: UInt16
    public var rows: UInt16

    public init(terminalID: UUID, cols: UInt16, rows: UInt16) {
        self.kind = "terminal.resize"
        self.terminalID = terminalID
        self.cols = cols
        self.rows = rows
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case terminalID = "terminal_id"
        case cols
        case rows
    }
}

public struct TerminalList: Codable, Equatable, Sendable {
    public var kind: String

    public init() {
        self.kind = "terminal.list"
    }
}

public struct TerminalListItem: Codable, Equatable, Sendable {
    public var terminalID: UUID
    public var title: String
    public var shell: String
    public var cwd: String?
    public var cols: UInt16
    public var rows: UInt16
    public var state: TerminalState
    public var createdAt: Date
    public var lastActiveAt: Date

    public init(
        terminalID: UUID,
        title: String,
        shell: String,
        cwd: String?,
        cols: UInt16,
        rows: UInt16,
        state: TerminalState,
        createdAt: Date,
        lastActiveAt: Date
    ) {
        self.terminalID = terminalID
        self.title = title
        self.shell = shell
        self.cwd = cwd
        self.cols = cols
        self.rows = rows
        self.state = state
        self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt
    }

    enum CodingKeys: String, CodingKey {
        case terminalID = "terminal_id"
        case title
        case shell
        case cwd
        case cols
        case rows
        case state
        case createdAt = "created_at"
        case lastActiveAt = "last_active_at"
    }
}

public struct TerminalListResult: Codable, Equatable, Sendable {
    public var kind: String
    public var terminals: [TerminalListItem]

    public init(terminals: [TerminalListItem]) {
        self.kind = "terminal.list.result"
        self.terminals = terminals
    }
}

public struct TerminalAttach: Codable, Equatable, Sendable {
    public var kind: String
    public var terminalID: UUID

    public init(terminalID: UUID) {
        self.kind = "terminal.attach"
        self.terminalID = terminalID
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case terminalID = "terminal_id"
    }
}

public struct TerminalAttached: Codable, Equatable, Sendable {
    public var kind: String
    public var terminal: TerminalListItem

    public init(terminal: TerminalListItem) {
        self.kind = "terminal.attached"
        self.terminal = terminal
    }
}

public struct TerminalClose: Codable, Equatable, Sendable {
    public var kind: String
    public var terminalID: UUID

    public init(terminalID: UUID) {
        self.kind = "terminal.close"
        self.terminalID = terminalID
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case terminalID = "terminal_id"
    }
}

public struct TerminalClosed: Codable, Equatable, Sendable {
    public var kind: String
    public var terminalID: UUID
    public var reason: String?

    public init(terminalID: UUID, reason: String? = nil) {
        self.kind = "terminal.closed"
        self.terminalID = terminalID
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case terminalID = "terminal_id"
        case reason
    }
}
