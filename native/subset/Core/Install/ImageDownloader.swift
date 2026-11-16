import Darwin
import Foundation

/// Downloads a release's disk image; `URLSessionImageDownloader` uses the network, tests pass recorded bytes.
public protocol ImageDownloading: Sendable {
    /// Writes the image at `url` into `file`, which this creates (mode 0600) and which must not exist, reporting the
    /// bytes received and the expected total. Throws an InstallFailure (step download), or CancellationError when the
    /// task is cancelled. The installer checks the file's SHA-256 afterwards.
    func download(_ url: URL, to file: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws
}

/// Downloads over HTTPS as install.mjs does: an ephemeral session, at most 5 redirects, each to an https: URL, no more
/// than 1 GiB, and a failure when no data arrives for 60 seconds.
public struct URLSessionImageDownloader: ImageDownloading {
    public static let maxBytes: Int64 = 1024 * 1024 * 1024
    static let maxRedirects = 5
    static let stall: TimeInterval = 60

    public init() {}

    public func download(_ url: URL, to file: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw InstallFailure(.download, "the image cannot be created in the private folder (\(String(cString: strerror(errno))))")
        }
        let delegate = DownloadDelegate(handle: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true), progress: progress)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = Self.stall
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let task = session.dataTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.setFinish { continuation.resume(with: $0) }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
    }
}

/// The session's delegate: writes each chunk to the file as it arrives. Its state is guarded by `lock`.
private final class DownloadDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let progress: @Sendable (Int64, Int64?) -> Void
    private var received: Int64 = 0
    private var expected: Int64?
    private var redirects = 0
    private var failure: InstallFailure?
    private var finish: ((Result<Void, Error>) -> Void)?

    func setFinish(_ callback: @escaping (Result<Void, Error>) -> Void) {
        lock.withLock { finish = callback }
    }

    init(handle: FileHandle, progress: @escaping @Sendable (Int64, Int64?) -> Void) {
        self.handle = handle
        self.progress = progress
    }

    private func fail(_ message: String, _ task: URLSessionTask) {
        lock.withLock { if failure == nil { failure = InstallFailure(.download, message) } }
        task.cancel()
    }

    func urlSession(
        _: URLSession, task: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let count = lock.withLock { redirects += 1; return redirects }
        if count > URLSessionImageDownloader.maxRedirects {
            fail("more than \(URLSessionImageDownloader.maxRedirects) redirects", task)
        } else if request.url?.scheme?.lowercased() != "https" {
            fail("redirected to a URL that is not https: (\(request.url?.scheme ?? "none"))", task)
        } else {
            return completionHandler(request)
        }
        completionHandler(nil)
    }

    func urlSession(
        _: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200...299).contains(status) else {
            fail("HTTP \(status)", dataTask)
            return completionHandler(.cancel)
        }
        let length = response.expectedContentLength
        if length > URLSessionImageDownloader.maxBytes {
            fail("the image is larger than \(URLSessionImageDownloader.maxBytes) bytes", dataTask)
            return completionHandler(.cancel)
        }
        lock.withLock { expected = length > 0 ? length : nil }
        completionHandler(.allow)
    }

    func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let (total, known) = lock.withLock { () -> (Int64, Int64?) in
            received += Int64(data.count)
            return (received, expected)
        }
        if total > URLSessionImageDownloader.maxBytes {
            return fail("the image is larger than \(URLSessionImageDownloader.maxBytes) bytes", dataTask)
        }
        do {
            // FileHandle.write writes the whole chunk or throws, so the file is exactly what was received.
            try handle.write(contentsOf: data)
        } catch {
            return fail("the image could not be written to the private folder (\(error.localizedDescription))", dataTask)
        }
        progress(total, known)
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle.close()
        let (callback, refused) = lock.withLock { () -> (((Result<Void, Error>) -> Void)?, InstallFailure?) in
            defer { finish = nil }
            return (finish, failure)
        }
        if let refused { return callback?(.failure(refused)) ?? () }
        guard let error else { return callback?(.success(())) ?? () }
        if (error as? URLError)?.code == .cancelled { return callback?(.failure(CancellationError())) ?? () }
        if (error as? URLError)?.code == .timedOut {
            return callback?(.failure(InstallFailure(.download, "no data for \(Int(URLSessionImageDownloader.stall)) seconds"))) ?? ()
        }
        callback?(.failure(InstallFailure(.download, error.localizedDescription)))
    }
}
