// Loads delivery metadata and decides whether a requested survey is allowed to appear.
// The default survey decision uses these rules for both screen and following requests.
import Foundation
import CoreFoundation

/// A delivered capture percentage and cooldowns, ready to evaluate against native survey history.
struct PresentationPolicy: Equatable {
    let capturePercent: Double
    let minTimeForRetake: Double?
    let minTimeForRetrigger: Double?
    var initialDelayMilliseconds: Double = 0

    /// Presentation calls this before allocating a popup. Return a suppression reason or nil to proceed;
    /// resumable Capture progress proceeds without resampling, while terminal history applies cooldowns.
    func evaluate(
        history: NativeRecord?,
        now: Int64,
        random: () -> Double
    ) -> SkyraNotShownReason? {
        if let history {
            switch history.status {
            case .capture:
                return nil
            case .rejected:
                guard
                    let delay = minTimeForRetrigger,
                    Double(now - history.updatedAt) / 1000 >= delay
                else {
                    return .rejectedCooldown
                }

            case .completed:
                guard
                    let delay = minTimeForRetake,
                    Double(now - history.updatedAt) / 1000 >= delay
                else {
                    return .completedCooldown
                }
            }
        }
        if capturePercent == 100 {
            return nil
        }
        if capturePercent == 0 {
            return .captureNotSelected
        }
        return random() < capturePercent / 100 ? nil : .captureNotSelected
    }

    /// Converts local policy evaluation into the combined decision consumed before any priority handoff.
    func decision(
        slug: String,
        history: NativeRecord?,
        now: Int64,
        random: () -> Double
    ) -> SkyraSurveyDecision {
        if let reason = evaluate(history: history, now: now, random: random) {
            return .notShown(reason)
        }
        return .present(slug: slug, initialDelayMilliseconds: initialDelayMilliseconds)
    }
}

/// Stateless delivery-request and decoding functions used by Skyra's injectable policy loader.
enum DeliveryMetadata {
    /// load and contract tests call this to validate delivery JSON and distinguish unavailable surveys
    /// from malformed responses. The result contains policy only, not the hosted survey renderer.
    static func decode(_ data: Data, status: Int, slug: String) throws -> PresentationPolicy? {
        if status == 403 || status == 404 {
            return nil
        }
        if status != 200 {
            throw SkyraError.deliveryHTTPStatus(status)
        }
        guard
            data.count <= 2_097_152,
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let survey = root["survey"] as? [String: Any]
        else {
            throw SkyraError.invalidDeliveryResponse
        }

        if
            let identity = survey["fullSlug"],
            (identity as? String) != slug
        {
            throw SkyraError.invalidDeliveryResponse
        }
        guard
            let render = survey["renderType"] as? String,
            let cards = survey["cards"] as? [Any]
        else {
            throw SkyraError.invalidDeliveryResponse
        }

        /// decode uses this to require finite nonnegative numeric policy fields, rejecting JSON booleans.
        func number(_ key: String, nullable: Bool) throws -> Double? {
            guard let value = survey[key] else {
                throw SkyraError.invalidDeliveryResponse
            }

            if nullable && value is NSNull {
                return nil
            }
            guard
                let value = value as? NSNumber,
                CFGetTypeID(value) != CFBooleanGetTypeID(),
                value.doubleValue.isFinite,
                value.doubleValue >= 0
            else {
                throw SkyraError.invalidDeliveryResponse
            }

            return value.doubleValue
        }
        let capture = try number("capturePercent", nullable: false)!
        if capture > 100 {
            throw SkyraError.invalidDeliveryResponse
        }

        let initialDelay = try survey["initialDelay"] == nil ? 0 : number(
            "initialDelay",
            nullable: false
        )!
        guard initialDelay <= Double(Int32.max) else {
            throw SkyraError.invalidDeliveryResponse
        }

        let policy = try PresentationPolicy(
            capturePercent: capture,
            minTimeForRetake: number("minTimeForRetake", nullable: true),
            minTimeForRetrigger: number("minTimeForRetrigger", nullable: true),
            initialDelayMilliseconds: initialDelay
        )
        return render == "App" && !cards.isEmpty ? policy : nil
    }

    /// Presentation's policy lookup calls this before creating a WebView. Fetch bounded, uncached metadata
    /// and tie the URLSession request to task cancellation so a dismissed request does not keep working.
    static func load(origin: URL?, slug: String) async throws -> PresentationPolicy? {
        guard let origin else {
            throw SkyraError.missingDeliveryOrigin
        }

        var url = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        url.path = "/survey/app/" + slug
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        let receiver = MetadataReceiver()
        let session = URLSession(
            configuration: configuration,
            delegate: receiver,
            delegateQueue: nil
        )
        defer {
            session.invalidateAndCancel()
        }
        var request = URLRequest(url: url.url!, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                receiver.continuation = continuation
                session.dataTask(with: request).resume()
            }
        }, onCancel: { session.invalidateAndCancel() })
        guard let response = response as? HTTPURLResponse else {
            throw SkyraError.invalidDeliveryResponse
        }

        return try decode(data, status: response.statusCode, slug: slug)
    }
}

/// A URLSession delegate that bounds response size while bytes arrive, rather than after buffering it all.
/// It is a class because URLSession retains one delegate across the request's asynchronous callbacks.
private final class MetadataReceiver: NSObject, URLSessionDataDelegate {
    var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var data = Data()
    private var oversized = false

    /// URLSession calls this for response headers. Cancel immediately if the declared body is oversized.
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        oversized = response.expectedContentLength > 2_097_152
        completionHandler(oversized ? .cancel : .allow)
    }

    /// URLSession calls this for each chunk. Enforce the byte limit even without a trustworthy content length.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        if data.count + chunk.count > 2_097_152 {
            oversized = true
            dataTask.cancel()
            return
        }

        data.append(chunk)
    }

    /// URLSession's terminal callback resumes the waiting loader with bytes or the transport/size error.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        defer {
            continuation = nil
        }
        if oversized {
            continuation?.resume(throwing: SkyraError.invalidDeliveryResponse)
        } else if let error {
            continuation?.resume(throwing: error)
        } else if let response = task.response {
            continuation?.resume(returning: (data, response))
        } else {
            continuation?.resume(throwing: SkyraError.invalidDeliveryResponse)
        }
    }

    /// URLSession asks before following a redirect. Refuse so delivery stays at the configured endpoint.
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
