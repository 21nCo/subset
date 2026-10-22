import Foundation

public struct HTTPResponseHead: Equatable, Sendable {
    public var status: Int
    /// Header names in lower case.
    public var headers: [String: String]
}

public enum HTTPParseError: Error, Equatable {
    case malformedHead
    case headTooLarge
    case malformedChunk
    case bodyTooLarge
    /// The connection closed before the response was complete.
    case truncated
}

/// An incremental HTTP/1.1 response parser for the daemon's replies: a JSON body with `content-length`, or an
/// event stream with chunked transfer encoding. Feed it bytes as they arrive, split anywhere.
public struct HTTPResponseParser: Sendable {
    public enum Event: Equatable, Sendable {
        case head(HTTPResponseHead)
        case body(Data)
        case end
    }

    private enum State: Sendable {
        case head, fixed(remaining: Int), chunkSize, chunkData(remaining: Int), chunkDataEnd, trailers, untilClose, done
    }

    static let maxHeadBytes = 64 * 1024
    private let maxBodyBytes: Int
    private var state = State.head
    private var buffer = Data()
    private var bodyBytes = 0

    /// `maxBodyBytes` limits the body; an event stream, which runs for as long as it is open, passes `Int.max`.
    public init(maxBodyBytes: Int = 8 * 1024 * 1024) {
        self.maxBodyBytes = maxBodyBytes
    }

    public var isComplete: Bool { if case .done = state { true } else { false } }

    public mutating func feed(_ data: Data) throws -> [Event] {
        buffer.append(data)
        var events: [Event] = []
        while true {
            switch try step() {
            case .event(let event): events.append(event)
            case .progressed: continue
            case .needMore: return events
            }
        }
    }

    /// The connection closed: ends a body that runs until close, and fails any other unfinished response.
    public mutating func finish() throws -> [Event] {
        switch state {
        case .done: return []
        case .untilClose:
            state = .done
            return [.end]
        default: throw HTTPParseError.truncated
        }
    }

    private mutating func line() throws -> String? {
        // A line, terminated or not yet, is limited like a head; the bytes after it are not part of it.
        let newline = buffer.firstIndex(of: 0x0A)
        if (newline ?? buffer.endIndex) - buffer.startIndex > Self.maxHeadBytes { throw HTTPParseError.headTooLarge }
        guard let newline else { return nil }
        var bytes = buffer[buffer.startIndex..<newline]
        if bytes.last == 0x0D { bytes = bytes.dropLast() }
        buffer.removeSubrange(buffer.startIndex...newline)
        guard let text = String(data: bytes, encoding: .utf8) else { throw HTTPParseError.malformedHead }
        return text
    }

    private mutating func take(upTo count: Int) -> Data {
        let taken = Data(buffer.prefix(count))
        buffer.removeFirst(taken.count)
        return taken
    }

    private enum Step {
        case event(Event), progressed, needMore
    }

    private mutating func step() throws -> Step {
        switch state {
        case .head:
            // The head is limited whether or not its end has arrived, and body bytes after it do not count.
            let end = buffer.range(of: Data("\r\n\r\n".utf8))
            if (end?.lowerBound ?? buffer.endIndex - min(3, buffer.count)) - buffer.startIndex > Self.maxHeadBytes {
                throw HTTPParseError.headTooLarge
            }
            guard let end else { return .needMore }
            let text = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8)
            buffer.removeSubrange(buffer.startIndex..<end.upperBound)
            guard let text else { throw HTTPParseError.malformedHead }
            var lines = text.components(separatedBy: "\r\n")
            let statusLine = lines.removeFirst().split(separator: " ", maxSplits: 2)
            guard statusLine.count >= 2, statusLine[0].hasPrefix("HTTP/1."), let status = Int(statusLine[1]) else { throw HTTPParseError.malformedHead }
            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { throw HTTPParseError.malformedHead }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
                state = .chunkSize
            } else if let length = headers["content-length"] {
                guard let count = Int(length), count >= 0 else { throw HTTPParseError.malformedHead }
                if count > maxBodyBytes { throw HTTPParseError.bodyTooLarge }
                state = .fixed(remaining: count)
            } else {
                state = status == 204 || status == 304 ? .fixed(remaining: 0) : .untilClose
            }
            return .event(.head(HTTPResponseHead(status: status, headers: headers)))
        case .fixed(let remaining):
            if remaining == 0 {
                state = .done
                return .event(.end)
            }
            guard !buffer.isEmpty else { return .needMore }
            let chunk = take(upTo: remaining)
            state = .fixed(remaining: remaining - chunk.count)
            return .event(.body(chunk))
        case .chunkSize:
            guard let line = try line() else { return .needMore }
            // Chunk extensions follow a semicolon.
            let hex = line.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard !hex.isEmpty, let size = Int(hex, radix: 16), size >= 0 else { throw HTTPParseError.malformedChunk }
            state = size == 0 ? .trailers : .chunkData(remaining: size)
            return .progressed
        case .chunkData(let remaining):
            guard !buffer.isEmpty else { return .needMore }
            let chunk = take(upTo: remaining)
            state = chunk.count == remaining ? .chunkDataEnd : .chunkData(remaining: remaining - chunk.count)
            return try counted(chunk)
        case .chunkDataEnd:
            guard let line = try line() else { return .needMore }
            guard line.isEmpty else { throw HTTPParseError.malformedChunk }
            state = .chunkSize
            return .progressed
        case .trailers:
            guard let line = try line() else { return .needMore }
            if line.isEmpty {
                state = .done
                return .event(.end)
            }
            return .progressed
        case .untilClose:
            guard !buffer.isEmpty else { return .needMore }
            return try counted(take(upTo: buffer.count))
        case .done:
            return .needMore
        }
    }

    private mutating func counted(_ chunk: Data) throws -> Step {
        bodyBytes += chunk.count
        if bodyBytes > maxBodyBytes { throw HTTPParseError.bodyTooLarge }
        return .event(.body(chunk))
    }
}

/// One server-sent event.
public struct ServerSentEvent: Equatable, Sendable {
    public var event: String
    public var data: String

    public init(event: String, data: String) {
        self.event = event
        self.data = data
    }
}

/// An incremental parser for `text/event-stream` (the WHATWG rules the daemon's `/v1/events` uses): `event:` and
/// `data:` fields, comments, any line ending, and frames split anywhere, including inside a UTF-8 character.
public struct ServerSentEventParser: Sendable {
    private var buffer = Data()
    private var event = ""
    private var data: [String] = []
    private var lastWasCR = false

    public init() {}

    public mutating func feed(_ bytes: Data) -> [ServerSentEvent] {
        var events: [ServerSentEvent] = []
        for byte in bytes {
            // A CR ends a line, and an LF right after it is part of the same line ending.
            if byte == 0x0A, lastWasCR {
                lastWasCR = false
                continue
            }
            lastWasCR = byte == 0x0D
            if byte == 0x0A || byte == 0x0D {
                if let dispatched = endLine() { events.append(dispatched) }
            } else {
                buffer.append(byte)
            }
        }
        return events
    }

    private mutating func endLine() -> ServerSentEvent? {
        let line = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll(keepingCapacity: true)
        if line.isEmpty {
            defer { (event, data) = ("", []) }
            // A frame without data dispatches nothing.
            return data.isEmpty ? nil : ServerSentEvent(event: event.isEmpty ? "message" : event, data: data.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil }
        let (field, value): (Substring, Substring) = if let colon = line.firstIndex(of: ":") {
            (line[..<colon], line[line.index(after: colon)...])
        } else {
            (Substring(line), "")
        }
        let trimmed = value.hasPrefix(" ") ? value.dropFirst() : value
        switch field {
        case "event": event = String(trimmed)
        case "data": data.append(String(trimmed))
        default: break
        }
        return nil
    }
}
