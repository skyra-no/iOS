// Defines exactly what survey progress may cross the bridge and be stored for later restoration.
// Typed free-text answers are absent from this schema, so decoding discards them as unknown fields.
import Foundation

/// Allowlisted hosted-page state. Unknown JSON fields are discarded during decoding.
public struct SkyraSavedState: Codable, Equatable {
    static let retentionMilliseconds: Int64 = 31_536_000_000
    private static let supportedVersion = 1
    private static let maximumJavaScriptInteger: Int64 = 9_007_199_254_740_991
    private static let languageUTF16Length = 2 ... 35
    private static let maximumHistoryCount = 1000
    private static let maximumMultiSelectCount = 500

    /// The hosted state names used for resumable progress and completed/rejected history.
    public enum Status: String, Codable {
        case capture = "Capture"
        case completed = "Completed"
        case rejected = "Rejected"
    }

    /// The hosted survey's current status and language, carried inside a saved snapshot.
    public struct Delivery: Codable, Equatable {
        public let state: Status
        public let language: String
    }

    /// Allowlisted selection IDs and booleans needed to restore progress without storing typed answers.
    public struct Variables: Codable, Equatable {
        public let task: String?
        public let segments: [String: String]?
        public let scales: [String: String]?
        public let singleSelect: [String: String]?
        public let multiSelect: [String: [String]]?
        public let completion: Bool?
        public let recruited: Bool?
    }

    /// The card position, visited-card history, and permitted selections to restore in the page.
    public struct Progress: Codable, Equatable {
        public let currentCard: Int
        public let history: [Int]
        public let variables: Variables
    }

    public let version: Int
    public let slug: String
    public let surveyId: String
    public let revision: Int
    public let visitorId: String
    public let sessionId: String
    public let sessionInitialized: Bool?
    public let updatedAt: Int64
    public let expiresAt: Int64
    public let skyraState: Delivery
    public let progress: Progress

    /// Bridge and StateStore call this before accepting a snapshot. Check identity, expiry, card bounds,
    /// and selection-token formats so malformed progress is neither applied nor persisted.
    func validate(now: Int64) throws {
        guard
            version == Self.supportedVersion,
            Identifiers.isValidSurveySlug(slug),
            UUID(uuidString: surveyId) != nil,
            revision >= 0,
            revision <= Self.maximumJavaScriptInteger,
            Identifiers.isValidVisitorID(visitorId),
            Identifiers.isValidSessionID(sessionId),
            updatedAt >= 0,
            updatedAt <= now,
            updatedAt <= Self.maximumJavaScriptInteger - Self.retentionMilliseconds,
            expiresAt == updatedAt + Self.retentionMilliseconds,
            expiresAt > now,
            Self.languageUTF16Length.contains(skyraState.language.utf16.count),
            progress.currentCard >= 0,
            progress.currentCard <= Self.maximumJavaScriptInteger,
            progress.history.count <= Self.maximumHistoryCount,
            progress.history.allSatisfy({ $0 >= 0 && $0 <= Self.maximumJavaScriptInteger })
        else {
            throw ContractError.invalid
        }

        let variables = progress.variables
        guard
            variables.task.map(Self.isValidToken) ?? true,
            [
                variables.segments,
                variables.scales,
                variables.singleSelect,
            ].allSatisfy({ dictionary in
                dictionary?.allSatisfy {
                    Self.isValidToken($0.key) && Self.isValidToken($0.value)
                } ?? true
            }),
            variables.multiSelect?.allSatisfy({ entry in
                Self.isValidToken(entry.key)
                    && entry.value.count <= Self.maximumMultiSelectCount
                    && entry.value.allSatisfy(Self.isValidToken)
            }) ?? true
        else {
            throw ContractError.invalid
        }
    }

    /// validate uses this for selection identifiers, restricting their alphabet and length.
    private static func isValidToken(_ value: String) -> Bool {
        Identifiers.matchesEntireString(value, pattern: "^[A-Za-z0-9]{1,22}$")
    }
}
