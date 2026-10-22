import Foundation
import Testing
@testable import TimerCore

/// Feeds `bytes` to a fresh parser in pieces of `size` bytes and collects every event.
private func parse(_ bytes: Data, pieces size: Int, maxBodyBytes: Int = .max) throws -> [HTTPResponseParser.Event] {
    var parser = HTTPResponseParser(maxBodyBytes: maxBodyBytes)
    var events: [HTTPResponseParser.Event] = []
    var offset = 0
    while offset < bytes.count {
        events += try parser.feed(bytes.subdata(in: offset..<min(bytes.count, offset + size)))
        offset += size
    }
    return events
}

private func body(_ events: [HTTPResponseParser.Event]) -> Data {
    events.reduce(into: Data()) { if case .body(let chunk) = $1 { $0.append(chunk) } }
}

@Test func contentLengthReplyParsesFromAnySplit() throws {
    let json = #"{"error":{"code":"invalid_state","message":"Timer t_00000000 is idle; only a running timer can pause."}}"#
    let reply = Data("HTTP/1.1 409 Conflict\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(json.utf8.count)\r\nConnection: close\r\n\r\n\(json)".utf8)
    for size in [1, 2, 7, 64, reply.count] {
        let events = try parse(reply, pieces: size)
        guard case .head(let head) = events.first else { Issue.record("no head"); return }
        #expect(head.status == 409)
        #expect(head.headers["content-type"] == "application/json; charset=utf-8")
        #expect(String(decoding: body(events), as: UTF8.self) == json)
        #expect(events.last == .end)
        #expect(events.filter { $0 == .end }.count == 1)
    }
}

@Test func chunkedEventStreamParsesFromAnySplit() throws {
    // Node writes each frame as one chunk; extensions and lower- or upper-case hex are valid too.
    let frames = ["event: state\ndata: {\"a\":1}\n\n", "event: heartbeat\ndata: {\"at\":5}\n\n", "event: alert\ndata: {\"é\":\"✓\"}\n\n"]
    var stream = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\nTransfer-Encoding: chunked\r\n\r\n"
    for (index, frame) in frames.enumerated() {
        let size = String(frame.utf8.count, radix: 16, uppercase: index == 1)
        stream += index == 2 ? "\(size);name=value\r\n\(frame)\r\n" : "\(size)\r\n\(frame)\r\n"
    }
    stream += "0\r\n\r\n"
    for size in [1, 3, 5, 11, 4096] {
        let events = try parse(Data(stream.utf8), pieces: size)
        #expect(String(decoding: body(events), as: UTF8.self) == frames.joined())
        #expect(events.last == .end)
    }
}

@Test func streamWithoutLengthEndsWhenTheConnectionCloses() throws {
    var parser = HTTPResponseParser()
    let events = try parser.feed(Data("HTTP/1.1 200 OK\r\n\r\npartial".utf8))
    #expect(body(events) == Data("partial".utf8))
    #expect(try parser.finish() == [.end])
}

@Test func malformedAndTruncatedRepliesFail() throws {
    var garbage = HTTPResponseParser()
    #expect(throws: HTTPParseError.malformedHead) { try garbage.feed(Data("SSH-2.0-OpenSSH\r\n\r\n".utf8)) }
    var badChunk = HTTPResponseParser()
    #expect(throws: HTTPParseError.malformedChunk) { try badChunk.feed(Data("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n".utf8)) }
    var truncated = HTTPResponseParser()
    _ = try truncated.feed(Data("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\n{\"a\"".utf8))
    #expect(throws: HTTPParseError.truncated) { try truncated.finish() }
    #expect(throws: HTTPParseError.bodyTooLarge) { try parse(Data("HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\n".utf8), pieces: 64, maxBodyBytes: 10) }
}

@Test func serverSentEventsHandlePartialFramesLineEndingsAndComments() {
    let text = ": comment\r\nevent: state\r\ndata: {\"timers\":\r\ndata: []}\r\n\r\nevent: heartbeat\rdata: {\"at\":1}\r\revent: empty\n\ndata:no-space\nid: 7\nretry: 10\n\nevent: alert\ndata: {\"name\":\"Tée ✓\"}\n\nevent: cut"
    let expected = [
        ServerSentEvent(event: "state", data: "{\"timers\":\n[]}"),
        ServerSentEvent(event: "heartbeat", data: "{\"at\":1}"),
        ServerSentEvent(event: "message", data: "no-space"),
        ServerSentEvent(event: "alert", data: "{\"name\":\"Tée ✓\"}")
    ]
    let bytes = Data(text.utf8)
    // Every split, including inside a CRLF pair and inside a multi-byte character, gives the same events.
    for size in [1, 2, 3, 13, bytes.count] {
        var parser = ServerSentEventParser()
        var events: [ServerSentEvent] = []
        var offset = 0
        while offset < bytes.count {
            events += parser.feed(bytes.subdata(in: offset..<min(bytes.count, offset + size)))
            offset += size
        }
        #expect(events == expected, "split \(size)")
        // The unterminated last frame is held until it ends.
        #expect(parser.feed(Data("\ndata: {}\n\n".utf8)) == [ServerSentEvent(event: "cut", data: "{}")])
    }
}

/// A connect function that plays back scripted attempts and records the waits between them.
private final class ScriptedDaemon: @unchecked Sendable {
    enum End { case close, fail, stayOpen }

    enum Attempt {
        case stream([String], then: End)
        case refuse
    }

    private let lock = NSLock()
    private var attempts: [Attempt]
    private(set) var sleeps: [TimeInterval] = []

    init(_ attempts: [Attempt]) {
        self.attempts = attempts
    }

    func connect() async throws -> AsyncThrowingStream<Data, Error> {
        let attempt = lock.withLock { attempts.isEmpty ? .refuse : attempts.removeFirst() }
        switch attempt {
        case .refuse:
            throw DaemonError.notListening
        case .stream(let chunks, let end):
            return AsyncThrowingStream { continuation in
                for chunk in chunks { continuation.yield(Data(chunk.utf8)) }
                if end != .stayOpen { continuation.finish(throwing: end == .fail ? DaemonError.timedOut : nil) }
            }
        }
    }

    func sleep(_ seconds: TimeInterval) {
        lock.withLock { sleeps.append(seconds) }
    }
}

@Test func subscriptionReconnectsWithBackoffAndResetsAfterConnecting() async {
    let daemon = ScriptedDaemon([
        // A frame split across reads, then the daemon ends the stream (as at shutdown).
        .stream(["event: state\nda", "ta: {\"n\":1}\n", "\nevent: heartbeat\ndata: {}\n\n"], then: .close),
        .refuse,
        .refuse,
        // The stream goes silent and the idle deadline fails it.
        .stream(["event: state\ndata: {\"n\":2}\n\n"], then: .fail),
        .stream(["event: state\ndata: {\"n\":3}\n\n"], then: .stayOpen)
    ])
    var backoff = EventSubscription.Backoff()
    backoff.maximum = 1.5
    let updates = EventSubscription.updates(connect: { try await daemon.connect() }, backoff: backoff, sleep: { daemon.sleep($0) })
    var log: [String] = []
    for await update in updates {
        switch update {
        case .connected: log.append("connected")
        case .event(let event): log.append("\(event.event) \(event.data)")
        case .disconnected(let error, let retryIn): log.append("disconnected \(error.map { "\($0)" } ?? "cleanly") \(retryIn)")
        }
        if log.last == "state {\"n\":3}" { break }
    }
    #expect(log == [
        "connected", "state {\"n\":1}", "heartbeat {}", "disconnected cleanly 0.5",
        "disconnected notListening 1.0", "disconnected notListening 1.5",
        "connected", "state {\"n\":2}", "disconnected timedOut 0.5",
        "connected", "state {\"n\":3}"
    ])
    #expect(daemon.sleeps == [0.5, 1.0, 1.5, 0.5])
}
