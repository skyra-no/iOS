// Runs one anonymous, uncached HTTP exchange for the decision client.
// Redirect, size, and cache rules live here, apart from the decision contract's request and response shapes.
import Foundation

/// Sends one request in its own ephemeral session and returns the bounded body and HTTP status.
enum BoundedTransport {
    /// Timeouts and the response-size cap that apply to one request.
    struct Limits: Equatable {
        let requestTimeout: TimeInterval
        let resourceTimeout: TimeInterval
        let maximumResponseBytes: Int
    }

    /// Callers pass the request with its method, headers, and body already set. The session has no
    /// cache, cookies, or credentials, and it refuses every redirect. Cancelling the calling task
    /// cancels the transfer and throws CancellationError. Responses over the cap throw invalidDecisionResponse.
    static func load(_ request: URLRequest, limits: Limits) async throws -> (Data, Int) {
        try Task.checkCancellation()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = limits.requestTimeout
        configuration.timeoutIntervalForResource = limits.resourceTimeout

        let receiver = BoundedReceiver(maximumBytes: limits.maximumResponseBytes)
        let session = URLSession(
            configuration: configuration,
            delegate: receiver,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        // The task exists before cancellation can reach it, and the session is invalidated only by
        // the defer above. Creating a task in an invalidated session raises an exception.
        let task = session.dataTask(with: request)

        let result: (Data, URLResponse)
        do {
            result = try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    // A cancellation that already arrived resumes here, and the task never starts.
                    if receiver.wait(with: continuation) {
                        task.resume()
                    }
                }
            }, onCancel: {
                task.cancel()
                receiver.finish(.failure(CancellationError()))
            })
        } catch {
            // URLSession reports cancellation as URLError; callers handle cancellation uniformly.
            try Task.checkCancellation()
            throw error
        }

        guard let response = result.1 as? HTTPURLResponse else {
            throw SkyraError.invalidDecisionResponse
        }

        return (result.0, response.statusCode)
    }
}

/// URLSession delegate that enforces one request's byte cap as chunks arrive and refuses redirects.
/// URLSession retains its delegate until invalidation, so the class also owns the waiting continuation.
/// The outcome and continuation are locked. The body is touched only on the delegate queue.
private final class BoundedReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maximumBytes: Int
    private var data = Data()
    private var oversized = false
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var outcome: Result<(Data, URLResponse), Error>?

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    /// Stores the caller's continuation and returns true, or resumes it at once and returns false
    /// when the request already ended.
    func wait(with continuation: CheckedContinuation<(Data, URLResponse), Error>) -> Bool {
        lock.lock()
        let outcome = outcome
        if outcome == nil {
            self.continuation = continuation
        }
        lock.unlock()

        guard let outcome else {
            return true
        }

        continuation.resume(with: outcome)
        return false
    }

    /// Ends the request with its first outcome and resumes the caller once. Later ones are dropped.
    func finish(_ outcome: Result<(Data, URLResponse), Error>) {
        lock.lock()
        guard self.outcome == nil else {
            lock.unlock()
            return
        }

        self.outcome = outcome
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(with: outcome)
    }

    /// URLSession calls this for response headers. Cancel immediately when the declared body is too large.
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        oversized = response.expectedContentLength > Int64(maximumBytes)
        completionHandler(oversized ? .cancel : .allow)
    }

    /// URLSession calls this for each chunk. Enforce the cap even when the content length was absent or wrong.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard data.count + chunk.count <= maximumBytes else {
            oversized = true
            dataTask.cancel()
            return
        }

        data.append(chunk)
    }

    /// URLSession's terminal callback ends the request with bytes or an error.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if oversized {
            finish(.failure(SkyraError.invalidDecisionResponse))
        } else if let error {
            finish(.failure(error))
        } else if let response = task.response {
            finish(.success((data, response)))
        } else {
            finish(.failure(SkyraError.invalidDecisionResponse))
        }
    }

    /// URLSession asks before following a redirect. Refuse it so every request stays at its configured endpoint.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
