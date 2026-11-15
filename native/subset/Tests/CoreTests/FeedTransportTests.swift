import Foundation
@testable import SubsetCore
import XCTest

/// Serves recorded HTTP responses to URLSession: no request reaches the network.
final class RecordedURLProtocol: URLProtocol {
    struct Response {
        var status: Int
        var headers: [String: String] = [:]
        var body = Data()
    }

    nonisolated(unsafe) static var response = Response(status: 200)
    /// Every URL requested, in order.
    nonisolated(unsafe) static var requested: [URL] = []

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requested.append(request.url!)
        // A followed redirect would ask for its target, which answers with a feed.
        let recorded = request.url?.host == "example.com" ? Response(status: 200, body: Data("{}".utf8)) : Self.response
        let http = HTTPURLResponse(url: request.url!, statusCode: recorded.status, httpVersion: "HTTP/1.1", headerFields: recorded.headers)!
        if let location = recorded.headers["Location"], let target = URL(string: location) {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: http)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        // In chunks, as a network delivers it.
        var offset = 0
        while offset < recorded.body.count {
            let end = min(offset + 16 * 1024, recorded.body.count)
            client?.urlProtocol(self, didLoad: recorded.body.subdata(in: offset..<end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class FeedTransportTests: XCTestCase {
    private let url = URL(string: "https://subset.21n.dev/catalog/v1.json")!

    private var transport: URLSessionFeedTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordedURLProtocol.self]
        return URLSessionFeedTransport(configuration: configuration)
    }

    func testTheFeedIsReadWhole() async throws {
        let body = try fixture("catalog-valid-live-and-beta")
        RecordedURLProtocol.response = .init(status: 200, body: body)
        let data = try await transport.fetch(url, limit: Catalog.maxBytes)
        XCTAssertEqual(data, body)
    }

    func testReadingStopsOneByteAfterTheLimit() async throws {
        RecordedURLProtocol.response = .init(status: 200, body: Data(repeating: 0x20, count: 3 * Catalog.maxBytes))
        let data = try await transport.fetch(url, limit: Catalog.maxBytes)
        XCTAssertEqual(data.count, Catalog.maxBytes + 1)
    }

    func testAnHTTPErrorIsUnavailable() async {
        RecordedURLProtocol.response = .init(status: 503, body: Data("busy".utf8))
        do {
            _ = try await transport.fetch(url, limit: Catalog.maxBytes)
            XCTFail("an HTTP error is read")
        } catch {
            XCTAssertEqual(error as? FeedUnavailable, FeedUnavailable("HTTP 503"))
        }
    }

    func testARedirectIsNotFollowed() async {
        RecordedURLProtocol.response = .init(status: 302, headers: ["Location": "https://example.com/catalog.json"])
        RecordedURLProtocol.requested = []
        do {
            let data = try await transport.fetch(url, limit: Catalog.maxBytes)
            XCTFail("a redirect is followed: \(data.count) bytes")
        } catch {
            XCTAssertTrue(error is FeedUnavailable, "\(error)")
        }
        XCTAssertEqual(RecordedURLProtocol.requested, [url])
    }
}
