// Defines the app-facing configuration/results and the retained Skyra instance that owns SDK state.
// Presentation.swift adds survey entry points; SurveySelection.swift resolves their decision.
import Foundation
#if canImport(UIKit)
import UIKit
import WebKit
#endif

/// App-supplied endpoints, identity traits, language, and persistence policy used when constructing Skyra.
public struct SkyraConfiguration {
    /// Selects whether native survey history survives the SDK instance or lasts only in memory.
    public enum Persistence {
        case persistent
        case ephemeral
    }

    public var hostedOrigin: URL
    /// Optional service override. Standard configuration reads its value from SkyraDefaults.
    public var deliveryOrigin: URL?
    public var language: String?
    public var traits: [String: String]
    public var persistence: Persistence
    public var organization: String?
    /// Optional complete survey decision override. Nil uses the SDK's default selection and policy.
    public var surveyDecision: (@MainActor (SkyraSurveyDecisionContext) async throws
        -> SkyraSurveyDecision)?

    /// Called by the app to describe its environment. Skyra.init validates these values before use.
    public init(
        hostedOrigin: URL = SkyraDefaults.hostedOrigin,
        language: String? = nil,
        traits: [String: String] = [:],
        persistence: Persistence = .persistent,
        deliveryOrigin: URL? = SkyraDefaults.deliveryOrigin,
        organization: String? = nil,
        surveyDecision: (@MainActor (SkyraSurveyDecisionContext) async throws
            -> SkyraSurveyDecision)? = nil
    ) {
        self.hostedOrigin = hostedOrigin
        self.language = language
        self.traits = traits
        self.persistence = persistence
        self.deliveryOrigin = deliveryOrigin
        self.organization = organization
        self.surveyDecision = surveyDecision
    }

    /// Skyra.init calls this to reject unsuitable endpoint URLs and oversized language/trait inputs.
    func validate() throws {
        if let deliveryOrigin {
            guard
                let origin = Origin(deliveryOrigin),
                origin.scheme == "https" || ["localhost", "127.0.0.1", "::1"].contains(origin.host),
                deliveryOrigin.user == nil,
                deliveryOrigin.password == nil,
                deliveryOrigin.query == nil,
                deliveryOrigin.fragment == nil,
                ["", "/"].contains(deliveryOrigin.path)
            else {
                throw SkyraError.invalidConfiguration
            }
        }
        guard
            let origin = Origin(hostedOrigin),
            origin.scheme == "https" || ["localhost", "127.0.0.1", "::1"].contains(origin.host),
            hostedOrigin.user == nil,
            hostedOrigin.password == nil,
            hostedOrigin.query == nil,
            hostedOrigin.fragment == nil,
            ["", "/"].contains(hostedOrigin.path),
            organization.map({ Identifiers.isValidSurveySlug("\($0)/survey") && !$0.contains("/")
            }) ?? true,
            language.map({ (2 ... 35).contains($0.utf16.count) }) ?? true,
            traits.allSatisfy({ $0.key.utf16.count <= 128 && $0.value.utf16.count <= 512 })
        else {
            throw SkyraError.invalidConfiguration
        }
    }
}

/// Explains why delivered policy or prior history prevented a request from creating a popup.
public enum SkyraNotShownReason: Equatable {
    case unavailable
    case captureNotSelected
    case rejectedCooldown
    case completedCooldown
}

/// The outcome returned by presentSurvey or delivered through an installation callback.
public enum SkyraResult: Equatable {
    case completed
    case rejected
    case interrupted
    case unavailable
    case notShown(reason: SkyraNotShownReason)
    case failure(String)
}

/// Native setup, ownership, storage, and delivery errors that presentation can throw to the app.
public enum SkyraError: Error, Equatable {
    case invalidConfiguration
    case missingOrganization
    case invalidSlug
    case alreadyPresenting
    case presenterUnavailable
    case storageFailure
    case missingDeliveryOrigin
    case invalidDeliveryResponse
    case deliveryHTTPStatus(Int)
}

/// An instance owns identity/storage policy and at most one active survey presentation.
/// The app retains this class so UIKit, SwiftUI, and asynchronous callbacks share the same owner.
@MainActor
public final class Skyra {
    /// Controls whether a request reuses interrupted progress or starts with a new survey session.
    public enum Restoration {
        case resumeInterrupted
        case fresh
    }

    let configuration: SkyraConfiguration
    let store: StateStore
    var sceneActive = true
    var loadPolicy: (URL?, String) async throws -> PresentationPolicy? = DeliveryMetadata.load
    var loadSurveyList: (URL?, String) async throws -> String? = SurveyList.select
    var random: () -> Double = { Double.random(in: 0 ..< 1) }
    /// Presentation uses an injectable wait so delay/cancellation tests need no wall-clock sleeps.
    var waitForDelay: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }
    #if canImport(UIKit)
    var active: SurveyController?
    /// A's live controller while a screen-visit-owned popup temporarily owns the foreground.
    var parkedFollowing: SurveyController?
    /// The screen visit that acquired foreground priority; it outlives its popup result.
    var screenPriorityVisit: UUID?
    /// True when a same-slug screen visit aliases A instead of temporarily parking it.
    var screenPriorityAliasesFollowing = false
    /// A screen-owned presentation still preparing; it must not displace `active` until reveal.
    var screenCandidateVisit: UUID?
    var screenCandidateController: SurveyController?
    var screenCandidatePending: PendingPresentation?
    var screenCandidateLifetime: ScreenVisitLifetime?
    var followingLifetime: FollowingLifetime?
    var followingHost: FollowingHost?
    var followingHostExpected = false
    var followingNow: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Native tests replace only the page transport, retaining real WebKit and UIKit ownership.
    var loadHostedPage: @MainActor (WKWebView, URLRequest) -> Void = { webView, request in
        webView.load(request)
    }

    var pendingPresentation: PendingPresentation?
    weak var presenter: UIViewController?
    var presenterDisconnectObserver: NSObjectProtocol?
    #endif

    /// Validate configuration and choose storage without fetching a survey or allocating visitor state.
    public init(configuration: SkyraConfiguration = .init(), storage: SkyraStorage? = nil) throws {
        try configuration.validate()
        self.configuration = configuration
        let selected = storage ??
            (configuration.persistence == .persistent ? SkyraUserDefaultsStorage() as SkyraStorage :
                SkyraMemoryStorage())
        store = StateStore(storage: selected, origin: Origin(configuration.hostedOrigin)!)
    }

    deinit {
        #if canImport(UIKit)
        if let presenterDisconnectObserver {
            NotificationCenter.default.removeObserver(presenterDisconnectObserver)
        }
        #endif
    }
}
