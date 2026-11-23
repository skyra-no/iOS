// The app-facing toolkit: configuration, errors, and the Skyra instance that stores state, asks the
// decision service, and syncs the state with the app and the web widget. It shows no UI.
import Foundation

/// What the app tells Skyra about itself when it creates the SDK.
public struct SkyraConfiguration: Sendable {
    /// Selects whether the visitor's state survives the app or lasts only in memory.
    public enum Persistence: Sendable {
        case persistent
        case ephemeral
    }

    /// Your organisation's identifier in Skyra.
    public var organization: String
    /// The language your app shows its content in, such as `nb` or `en`. The device's own language
    /// setting is sent separately.
    public var language: String?
    /// Traits that hold for the whole app session, such as `plan`. `getSurveys(traits:)` adds traits
    /// that change, such as the current screen. Every request also carries `channel: app`, the trait
    /// a survey's audience rule targets to show in the app and not on the website.
    public var traits: [String: String]
    public var persistence: Persistence
    /// The decision service. Override it only for development environments.
    public var decisionOrigin: URL

    public init(
        organization: String,
        language: String? = nil,
        traits: [String: String] = [:],
        persistence: Persistence = .persistent,
        decisionOrigin: URL = SkyraDefaults.decisionOrigin
    ) {
        self.organization = organization
        self.language = language
        self.traits = traits
        self.persistence = persistence
        self.decisionOrigin = decisionOrigin
    }

    // These limits are the decision service's own, so the SDK never sends a request it refuses.

    /// A language tag such as `nb`, `en-GB` or `zh-Hant-TW`, of at most 35 characters. Apps put it
    /// into HTML, so only these characters pass.
    static let languagePattern = "^[A-Za-z]{2,3}(-[A-Za-z]{4})?(-([A-Za-z]{2}|[0-9]{3}))?"
        + "(-([A-Za-z0-9]{5,8}|[0-9][A-Za-z0-9]{3}))*$"
    static let maximumLanguageLength = 35
    /// A time zone name such as `Europe/Oslo`, of at most 64 characters.
    static let timeZonePattern = "^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$"
    static let maximumTimeZoneLength = 64
    /// The most traits one request may carry, `channel` included.
    static let maximumTraitCount = 50
    /// The longest trait value, in characters.
    static let maximumTraitValueLength = 256

    /// Skyra.init calls this to reject an unusable organisation, service address, language, or traits.
    func validate() throws {
        guard
            Identifiers.isValidSlug(organization),
            let scheme = decisionOrigin.scheme?.lowercased(),
            let host = decisionOrigin.host?.lowercased(),
            !host.isEmpty,
            scheme == "https" ||
            (scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)),
            decisionOrigin.user == nil,
            decisionOrigin.password == nil,
            decisionOrigin.query == nil,
            decisionOrigin.fragment == nil,
            ["", "/"].contains(decisionOrigin.path),
            language.map(Self.isValidLanguage) ?? true,
            Self.areValid(traits)
        else {
            throw SkyraError.invalidConfiguration
        }
    }

    /// The configured language and each survey's language in a decision must pass the same check.
    static func isValidLanguage(_ language: String) -> Bool {
        language.utf8.count <= maximumLanguageLength
            && Identifiers.matchesEntireString(language, pattern: languagePattern)
    }

    /// The device's time zone name is sent only when the service would accept it.
    static func isValidTimeZone(_ timeZone: String) -> Bool {
        timeZone.utf8.count <= maximumTimeZoneLength
            && Identifiers.matchesEntireString(timeZone, pattern: timeZonePattern)
    }

    /// Traits have the same limits wherever they are supplied: names are slugs, values are short,
    /// and together with the traits every request carries they stay within the count.
    static func areValid(_ traits: [String: String]) -> Bool {
        traits.merging(SkyraDefaults.traits) { _, fixed in fixed }.count <= maximumTraitCount
            && traits.allSatisfy {
                Identifiers.isValidSlug($0.key)
                    && $0.value.unicodeScalars.count <= maximumTraitValueLength
            }
    }
}

/// Errors the SDK throws. A decision request can also throw `URLError`, for example when it times out,
/// and `CancellationError` when its task is cancelled.
public enum SkyraError: Error, Equatable {
    /// The organisation, service address, language, or configured traits are not usable.
    case invalidConfiguration
    /// The traits passed to `getSurveys(traits:)` are too many, or one has a name that is not a
    /// slug, or a value that is too long.
    case invalidTraits
    /// The state passed to `sync` is not readable, has no valid visitor ID, or has a visitor ID
    /// dated in the future.
    case invalidState
    /// The state could not be read from or written to storage.
    case storageFailure
    /// The decision request would exceed the service's 64 KB limit.
    case requestTooLarge
    /// The decision service answered with this HTTP status. 404 means it does not know the organisation.
    case decisionHTTPStatus(Int)
    /// The decision service's answer could not be understood.
    case invalidDecisionResponse
}

extension SkyraError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "The Skyra organisation, service address, language or traits are not usable."
        case .invalidTraits:
            return "The traits are too many, or one has an unusable name or a value that is too long."
        case .invalidState:
            return "The Skyra state is not readable or has no valid visitor ID."
        case .storageFailure:
            return "The Skyra state could not be read or written."
        case .requestTooLarge:
            return "The Skyra decision request is larger than the service accepts."
        case let .decisionHTTPStatus(status):
            return "The Skyra decision service answered with HTTP status \(status)."
        case .invalidDecisionResponse:
            return "The Skyra decision service's answer could not be understood."
        }
    }
}

/// Stores a visitor's survey state, asks Skyra which surveys to show, and merges in what happened.
///
/// Create one instance and keep it. It is safe to use from any thread. It never presents anything:
/// the app shows each survey itself, usually with the Skyra widget in its own web view.
public final class Skyra: @unchecked Sendable {
    /// The version of this package, such as `0.1.0`.
    public static let version = SkyraDefaults.sdkVersion

    typealias Decide = @Sendable (URL, DecisionRequest) async throws -> [SkyraSurvey]

    let configuration: SkyraConfiguration
    let store: StateStore
    private let decide: Decide
    /// The traits of the latest `getSurveys(traits:)` call, so the widget is told the same.
    private var momentTraits: [String: String] = [:]
    private let momentLock = NSLock()

    /// Validates the configuration and chooses storage. Makes no request and stores nothing yet.
    /// Pass `storage` to keep the state somewhere other than UserDefaults, such as an app group.
    public convenience init(
        configuration: SkyraConfiguration,
        storage: SkyraStorage? = nil
    ) throws {
        try self.init(
            configuration: configuration,
            storage: storage,
            clock: Clock.nowMilliseconds,
            decide: { try await DecisionService.decide(origin: $0, request: $1) }
        )
    }

    /// Tests inject a clock and a decision service to stay off the wall clock and the network.
    init(
        configuration: SkyraConfiguration,
        storage: SkyraStorage?,
        clock: @escaping () -> Int64,
        decide: @escaping Decide
    ) throws {
        try configuration.validate()
        self.configuration = configuration
        self.decide = decide
        let selected = storage ??
            (configuration.persistence == .persistent ? SkyraUserDefaultsStorage() as SkyraStorage :
                SkyraMemoryStorage())
        store = StateStore(
            storage: selected,
            organization: configuration.organization,
            clock: clock
        )
    }

    // MARK: Decision

    /// Asks the decision service which surveys this visitor may see in the app right now.
    ///
    /// Returns the surveys the decision service allows, in its order. The service decides, using the
    /// stored state sent with the request. An empty list means there is nothing to show. The app chooses where and when each one shows.
    ///
    /// Pass the traits that describe this moment, such as `["screen": "checkout"]`. They are added to the
    /// configured traits and win when both name the same trait. Call this when the screen or a trait
    /// changes, not in a loop. The request gives up after 1.5 seconds and is never retried.
    ///
    /// Nothing is recorded about the returned surveys. Store what the visitor does with `sync(_:)`.
    public func getSurveys(traits: [String: String] = [:]) async throws -> [SkyraSurvey] {
        try Task.checkCancellation()
        guard SkyraConfiguration.areValid(traits) else {
            throw SkyraError.invalidTraits
        }

        let sent = allTraits(traits)
        guard sent.count <= SkyraConfiguration.maximumTraitCount else {
            throw SkyraError.invalidTraits
        }

        momentLock.withLock { momentTraits = traits }
        let device = await DecisionDevice.current()
        let timeZone = TimeZone.current.identifier
        let request = DecisionRequest(
            organization: configuration.organization,
            device: device.deviceClass,
            language: configuration.language,
            locale: Locale.preferredLanguages.first.flatMap {
                SkyraConfiguration.isValidLanguage($0) ? $0 : nil
            },
            timeZone: SkyraConfiguration.isValidTimeZone(timeZone) ? timeZone : "UTC",
            traits: sent,
            state: try store.snapshot(),
            userAgent: device.userAgent
        )
        let allowed = try await decide(configuration.decisionOrigin, request)
        try Task.checkCancellation()
        return allowed
    }

    /// The configured traits, then the traits for this moment, then the traits every app request
    /// carries. A later one wins, so `channel` is always `app`.
    private func allTraits(_ moment: [String: String]) -> [String: String] {
        configuration.traits
            .merging(moment) { _, moment in moment }
            .merging(SkyraDefaults.traits) { _, fixed in fixed }
    }

    // MARK: The widget in a web view

    /// The name of the script message handler `widgetConfig` posts to.
    public static let messageHandlerName = "skyra"

    /// JavaScript that sets `window.SKYRA_CONFIG` for the Skyra widget in your own web view. Put it
    /// in a `<script>` before the widget's script.
    ///
    /// It gives the widget the organisation, the traits the latest `getSurveys(traits:)` call sent,
    /// and a store filled with this visitor's state. Whatever the widget saves is posted to the script
    /// message handler named `skyra`; pass each message to `sync(_:)` as `SkyraState(widget:)`.
    public func widgetConfig() throws -> String {
        let traits = momentLock.withLock { momentTraits }
        let config: [String: Any] = [
            "org": configuration.organization,
            "traits": allTraits(traits),
        ]
        let handler = "window.webkit.messageHandlers.\(Self.messageHandlerName)"
        return """
        (() => {
          const saved = \(try Self.script(store.snapshot().widgetObject))
          const send = () => \(handler).postMessage(saved)
          window.SKYRA_CONFIG = Object.assign(\(try Self.script(config)), {
            store: {
              state: {
                read: () => saved.state,
                write: state => { saved.state = state; send() },
                clear: () => {},
              },
              progress: {
                read: slug => saved.progress[slug] ?? null,
                write: (slug, progress) => { saved.progress[slug] = progress; send() },
                clear: slug => { delete saved.progress[slug]; send() },
              },
            },
          })
        })()
        """
    }

    /// JSON that is safe inside a `<script>` element: nothing in it can end the element or a line.
    private static func script(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "<", with: "\\u003c")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    // MARK: State and sync

    /// The visitor's whole state: the visitor ID and the last state of each survey. A first call
    /// creates the visitor ID.
    public func state() throws -> SkyraState {
        try store.snapshot()
    }

    /// Merges a copy of the visitor's state into this device's copy, stores the result, and returns it.
    ///
    /// This is the one way state is written. Use it to record what the visitor did with a survey, and
    /// to take in the web widget's copy when your app also shows Skyra in a web view:
    ///
    /// - The visitor ID that was created first is kept.
    /// - For each survey, the entry with the later time wins. When the times are equal, the state
    ///   that is further along wins.
    /// - Surveys of other organisations, entries older than 400 days and entries dated more than five
    ///   minutes ahead are ignored.
    /// - At most 200 surveys are kept, the latest first.
    ///
    /// The decision service keeps nothing per visitor. It decides from the state stored here.
    @discardableResult
    public func sync(_ state: SkyraState) throws -> SkyraState {
        guard Identifiers.isValidVisitorID(state.visitorId) else {
            throw SkyraError.invalidState
        }

        return try store.merge(state)
    }
}
