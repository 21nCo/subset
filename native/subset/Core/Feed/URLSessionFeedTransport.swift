import Foundation

/// Fetches the feed over https with URLSession: no cookies, credentials or URL cache, redirects refused, and a
/// 20-second limit, as `subset` fetches it. Reading stops after `limit + 1` bytes.
public struct URLSessionFeedTransport: FeedTransport {
    public static let timeout: TimeInterval = 20
    private let configuration: URLSessionConfiguration

    /// `configuration` defaults to an ephemeral one; tests pass one with a stub URLProtocol.
    public init(configuration: URLSessionConfiguration = .ephemeral) {
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.timeoutIntervalForRequest = Self.timeout
        configuration.timeoutIntervalForResource = Self.timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        self.configuration = configuration
    }

    public func fetch(_ url: URL, limit: Int) async throws -> Data {
        let session = URLSession(configuration: configuration, delegate: RedirectRefuser(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw FeedUnavailable(Self.reason(error))
        }
        guard let http = response as? HTTPURLResponse else { throw FeedUnavailable("not an HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            bytes.task.cancel()
            throw FeedUnavailable("HTTP \(http.statusCode)")
        }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > limit {
                    bytes.task.cancel()
                    break
                }
            }
        } catch {
            throw FeedUnavailable(Self.reason(error))
        }
        return data
    }

    static func reason(_ error: any Error) -> String {
        guard let error = error as? URLError else { return "\(error)" }
        switch error.code {
        case .timedOut: return "no answer within \(Int(timeout)) seconds"
        case .notConnectedToInternet: return "not connected to the internet"
        case .cannotFindHost, .dnsLookupFailed: return "the host cannot be found"
        case .cancelled: return "cancelled"
        default: return error.localizedDescription
        }
    }
}

// Refuses every redirect: the 3xx response is then the answer, and an HTTP error.
private final class RedirectRefuser: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse, newRequest _: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
