// Resolves and qualifies one survey decision before presentation considers priority or handoff.
import Foundation

/// The complete business decision for one survey request.
///
/// A present decision is qualified by the configured decision function. The SDK still validates its
/// identity and delay and enforces presentation ownership and host safety, but does not re-run policy.
public enum SkyraSurveyDecision: Equatable {
    case present(slug: String, initialDelayMilliseconds: Double = 0)
    case notShown(SkyraNotShownReason)
}

/// Inputs and the SDK's opt-in default business decision for one request.
///
/// The context intentionally exposes no native history or identity. A custom decision may call
/// `defaultDecision()` to reuse the SDK's list, metadata, and local-history implementation.
@MainActor
public struct SkyraSurveyDecisionContext {
    public let organization: String?
    public let requestedSlug: String?

    private let defaultOperation: DefaultSurveyDecisionOperation

    init(
        organization: String?,
        requestedSlug: String?,
        defaultOperation: @escaping @MainActor () async throws -> SkyraSurveyDecision
    ) {
        self.organization = organization
        self.requestedSlug = requestedSlug
        self.defaultOperation = DefaultSurveyDecisionOperation(defaultOperation)
    }

    /// Resolve the complete SDK-default decision once for this request, including local eligibility.
    /// Repeated or concurrent calls share the same result and never repeat capture sampling or I/O.
    public func defaultDecision() async throws -> SkyraSurveyDecision {
        try await defaultOperation.value()
    }
}

/// Per-context memoization: custom decision closures may compose with the SDK default without
/// accidentally making multiple list/metadata requests or sampling capture more than once.
@MainActor
private final class DefaultSurveyDecisionOperation {
    private let operation: @MainActor () async throws -> SkyraSurveyDecision
    private var task: Task<SkyraSurveyDecision, Error>?

    init(_ operation: @escaping @MainActor () async throws -> SkyraSurveyDecision) {
        self.operation = operation
    }

    func value() async throws -> SkyraSurveyDecision {
        try Task.checkCancellation()
        let task = self.task ?? Task { @MainActor [operation] in
            try await operation()
        }
        self.task = task

        return try await withTaskCancellationHandler(operation: {
            let decision = try await task.value
            try Task.checkCancellation()
            return decision
        }, onCancel: {
            task.cancel()
        })
    }
}

/// Internal list lookup used by the default decision before qualifying the selected survey.
@MainActor
enum SurveyList {
    static func select(origin: URL?, organization: String) async throws -> String? {
        try Task.checkCancellation()
        guard let origin else {
            throw SkyraError.missingDeliveryOrigin
        }
        guard Self.isValidOrigin(origin), Self.isValidOrganization(organization) else {
            throw SkyraError.invalidConfiguration
        }

        let url = Self.url(origin: origin, organization: organization)
        let (data, status) = try await SurveyListTransport.load(url: url)
        try Task.checkCancellation()
        return try Self.decode(data, status: status, organization: organization)
    }

    /// Decodes the list contract independently of transport for hermetic contract tests.
    static func decode(_ data: Data, status: Int, organization: String) throws -> String? {
        guard status == 200 else {
            throw SkyraError.deliveryHTTPStatus(status)
        }
        guard
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let surveys = root["surveys"] as? [Any]
        else {
            throw SkyraError.invalidDeliveryResponse
        }

        for value in surveys {
            guard
                let survey = value as? [String: Any],
                let renderType = survey["renderType"] as? String
            else {
                throw SkyraError.invalidDeliveryResponse
            }
            guard renderType == "App" else {
                continue
            }
            guard
                let slug = survey["fullSlug"] as? String,
                Identifiers.isValidSurveySlug(slug),
                slug.split(separator: "/", omittingEmptySubsequences: false).first.map(String.init)
                == organization
            else {
                throw SkyraError.invalidDeliveryResponse
            }

            return slug
        }
        return nil
    }

    private static func isValidOrganization(_ organization: String) -> Bool {
        Identifiers.isValidSurveySlug("\(organization)/survey")
            && !organization.contains("/")
    }

    private static func isValidOrigin(_ url: URL) -> Bool {
        guard
            let origin = Origin(url),
            origin.scheme == "https" || ["localhost", "127.0.0.1", "::1"].contains(origin.host),
            url.user == nil,
            url.password == nil,
            url.query == nil,
            url.fragment == nil,
            ["", "/"].contains(url.path)
        else {
            return false
        }

        return true
    }

    private static func url(origin: URL, organization: String) -> URL {
        var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        components.path = "/survey/\(organization)"
        return components.url!
    }
}

extension Skyra {
    /// Resolve one complete selection-and-eligibility decision before presentation can hand off priority.
    /// Custom configuration replaces the entire business decision; SDK identity, delay, host, and
    /// presentation-safety checks remain enforced here and by the presentation owner.
    func resolvePresentationDecision(slug: String?) async throws -> SkyraSurveyDecision {
        try Task.checkCancellation()
        if let slug, !Identifiers.isValidSurveySlug(slug) {
            throw SkyraError.invalidSlug
        }
        guard slug != nil || configuration.organization != nil else {
            throw SkyraError.missingOrganization
        }

        let context = SkyraSurveyDecisionContext(
            organization: configuration.organization,
            requestedSlug: slug
        ) { [weak self] in
            guard let self else {
                throw CancellationError()
            }

            return try await self.defaultSurveyDecision(requestedSlug: slug)
        }
        let decision: SkyraSurveyDecision
        if let configured = configuration.surveyDecision {
            decision = try await configured(context)
        } else {
            decision = try await context.defaultDecision()
        }
        try Task.checkCancellation()
        return try validate(decision, requestedSlug: slug)
    }

    private func defaultSurveyDecision(requestedSlug: String?) async throws -> SkyraSurveyDecision {
        try Task.checkCancellation()
        let slug: String
        if let requestedSlug {
            slug = requestedSlug
        } else {
            guard let organization = configuration.organization else {
                throw SkyraError.missingOrganization
            }

            let selection = try await loadSurveyList(configuration.deliveryOrigin, organization)
            try Task.checkCancellation()
            guard let selected = selection else {
                return .notShown(.unavailable)
            }
            guard
                Identifiers.isValidSurveySlug(selected),
                selected.split(
                    separator: "/",
                    omittingEmptySubsequences: false
                ).first.map(String.init)
                == organization
            else {
                throw SkyraError.invalidSlug
            }

            slug = selected
        }

        let policy = try await loadPolicy(configuration.deliveryOrigin, slug)
        try Task.checkCancellation()
        guard let policy else {
            return .notShown(.unavailable)
        }

        let history = try store.history(slug: slug)
        try Task.checkCancellation()
        return policy.decision(
            slug: slug,
            history: history,
            now: store.clock(),
            random: random
        )
    }

    private func validate(
        _ decision: SkyraSurveyDecision,
        requestedSlug: String?
    ) throws -> SkyraSurveyDecision {
        guard case .present(let slug, let delay) = decision else {
            return decision
        }
        guard Identifiers.isValidSurveySlug(slug) else {
            throw SkyraError.invalidSlug
        }

        if let requestedSlug, slug != requestedSlug {
            throw SkyraError.invalidConfiguration
        }
        if
            requestedSlug == nil, let organization = configuration.organization,
            slug.split(separator: "/", omittingEmptySubsequences: false).first.map(String.init)
            != organization
        {
            throw SkyraError.invalidSlug
        }
        guard delay.isFinite, (0 ... Double(Int32.max)).contains(delay) else {
            throw SkyraError.invalidConfiguration
        }

        return decision
    }
}

/// Owns a single anonymous, bounded delivery-list request.
private enum SurveyListTransport {
    @MainActor
    static func load(url: URL) async throws -> (Data, Int) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20

        let receiver = SurveyListReceiver()
        let session = URLSession(
            configuration: configuration,
            delegate: receiver,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "GET"
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                receiver.continuation = continuation
                session.dataTask(with: request).resume()
            }
        }, onCancel: {
            session.invalidateAndCancel()
        })
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else {
            throw SkyraError.invalidDeliveryResponse
        }

        return (data, response.statusCode)
    }
}

/// URLSession delegate that bounds response bytes and refuses redirects.
private final class SurveyListReceiver: NSObject, URLSessionDataDelegate {
    var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var data = Data()
    private var oversized = false

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        oversized = response.expectedContentLength > 2_097_152
        completionHandler(oversized ? .cancel : .allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        guard data.count + chunk.count <= 2_097_152 else {
            oversized = true
            dataTask.cancel()
            return
        }

        data.append(chunk)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        defer { continuation = nil }
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
