import Darwin
import Foundation
import Testing
@testable import TimerCore

/// One Unix socket listener in a short temp folder, answering a single `/v1/events` request as the daemon does.
private final class FakeEventDaemon: @unchecked Sendable {
    let dir: String
    private let listener: Int32

    init() throws {
        dir = "/tmp/tt-" + UUID().uuidString.prefix(8).lowercased()
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: false)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array((dir + "/daemon.sock").utf8)) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(listener, 1) == 0 else { throw POSIXError(.EADDRINUSE) }
    }

    deinit {
        close(listener)
        try? FileManager.default.removeItem(atPath: dir)
    }

    var client: DaemonClient { DaemonClient(paths: DaemonPaths(dataDir: dir)) }

    /// Accepts the client, reads its request, and starts a chunked event stream with one frame.
    func accept() -> Int32 {
        let fd = Darwin.accept(listener, nil, nil)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !request.contains(Data("\r\n\r\n".utf8)) {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            request.append(contentsOf: buffer[..<count])
        }
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\nTransfer-Encoding: chunked\r\n\r\n"
        _ = Array((head + Self.chunk(Self.frame(1))).utf8).withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        return fd
    }

    static func frame(_ n: Int, padding: Int = 0) -> String {
        "event: state\ndata: {\"n\":\(n),\"pad\":\"\(String(repeating: "x", count: padding))\"}\n\n"
    }

    static func chunk(_ frame: String) -> String {
        String(frame.utf8.count, radix: 16) + "\r\n" + frame + "\r\n"
    }

    /// Writes frames without blocking until `limit` bytes are accepted or the client stops taking them for
    /// `stall` seconds, and returns how many bytes the client took.
    static func flood(_ fd: Int32, limit: Int, stall: TimeInterval) -> Int {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        defer { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK) }
        var written = 0
        var pending = [UInt8]()
        var n = 2
        var idleSince = Date()
        while written < limit, Date().timeIntervalSince(idleSince) < stall {
            if pending.isEmpty {
                pending = Array(chunk(frame(n, padding: 16 * 1024)).utf8)
                n += 1
            }
            let count = pending.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if count > 0 {
                written += count
                pending.removeFirst(count)
                idleSince = Date()
            } else {
                usleep(10_000)
            }
        }
        return written
    }

    /// Whether the client closes its end within `seconds`.
    static func closes(_ fd: Int32, within seconds: Int) -> Bool {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count == 0 { return true }
            if count < 0 { return errno != EAGAIN && errno != EWOULDBLOCK }
        }
    }
}

private func onThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        Thread.detachNewThread { continuation.resume(returning: body()) }
    }
}

@Test func theEventStreamReadsOnlyAsFastAsItsConsumer() async throws {
    let daemon = try FakeEventDaemon()
    var client = daemon.client
    client.streamIdleTimeout = 0.3
    let accepted = Task { await onThread { daemon.accept() } }
    var bytes: AsyncThrowingStream<Data, Error>.AsyncIterator? = try await client.openEvents().makeAsyncIterator()
    let fd = await accepted.value
    #expect(try await bytes?.next() != nil)

    // The consumer stops reading. The daemon must see that, as server.mjs counts on to coalesce and drop
    // a stalled subscriber, rather than this process taking every byte into memory.
    let written = await onThread { FakeEventDaemon.flood(fd, limit: 32 * 1024 * 1024, stall: 0.5) }
    #expect(written < 4 * 1024 * 1024, "the client took \(written) bytes while its consumer was stalled")

    // A pause longer than the idle deadline is the consumer's, not a silent daemon: the rest still arrives.
    // `written` counts chunk framing too, about 8 bytes in each 16 KiB.
    var received = 0
    while received < written - written / 100, let chunk = try await bytes?.next() { received += chunk.count }

    // Dropping the stream closes the connection.
    bytes = nil
    #expect(await onThread { FakeEventDaemon.closes(fd, within: 3) })
    close(fd)
}

@Test func aSilentEventStreamStillTimesOut() async throws {
    let daemon = try FakeEventDaemon()
    var client = daemon.client
    client.streamIdleTimeout = 0.3
    let accepted = Task { await onThread { daemon.accept() } }
    var bytes = try await client.openEvents().makeAsyncIterator()
    let fd = await accepted.value
    defer { close(fd) }
    #expect(try await bytes.next() != nil)
    let started = ContinuousClock.now
    await #expect(throws: DaemonError.timedOut) { _ = try await bytes.next() }
    #expect(ContinuousClock.now - started < .seconds(3))
}

@Test func theSubscriptionPullsBytesOnlyWhenItsConsumerAsks() async throws {
    let pulled = Counter()
    // An endless stream that counts how many chunks were taken from it.
    let connect: EventSubscription.Connect = {
        AsyncThrowingStream(unfolding: {
            let n = pulled.increment()
            return Data(FakeEventDaemon.frame(n).utf8)
        })
    }
    var updates = EventSubscription.updates(connect: connect).makeAsyncIterator()
    guard case .connected = await updates.next() else { Issue.record("not connected"); return }
    guard case .event(let first) = await updates.next() else { Issue.record("no event"); return }
    #expect(first.data.hasPrefix("{\"n\":1,"))
    try await Task.sleep(for: .milliseconds(200))
    #expect(pulled.value == 1, "pulled \(pulled.value) chunks while the consumer was stalled")
    guard case .event(let second) = await updates.next() else { Issue.record("no event"); return }
    #expect(second.data.hasPrefix("{\"n\":2,"))
    #expect(pulled.value == 2)
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}
