// Defines the visitor state the decision contract calls `skyraState`: one visitor ID and one entry per survey.
// It is stored on the device, sent with every decision request, and exchanged with the web widget.
import Foundation
import CoreFoundation

/// Everything Skyra knows about one visitor on this device.
///
/// Read it with `Skyra.state()`. Pass the widget's copy to `Skyra.sync(_:)` to merge the two.
public struct SkyraState: Equatable, Sendable {
    /// What the visitor last did with a survey.
    public enum Status: String, Sendable {
        /// The survey was shown to the visitor.
        case selected = "Selected"
        /// The visitor started answering.
        case capture = "Capture"
        /// The visitor finished the survey.
        case completed = "Completed"
        /// The visitor closed the survey before finishing it.
        case rejected = "Rejected"

        /// How far along a state is. Sync uses it to break a tie between two entries with the same time.
        var rank: Int {
            switch self {
            case .selected:
                return 0
            case .capture:
                return 1
            case .rejected:
                return 2
            case .completed:
                return 3
            }
        }
    }

    /// One survey's last state, when it happened, and the session it belongs to.
    public struct Survey: Equatable, Sendable {
        public var state: Status
        /// Unix time in milliseconds of `state`.
        public var lastSync: Int64
        /// The session the visitor is answering in, or answered in. Nil until the visitor starts answering.
        public var sessionId: String?
        /// Where the visitor is in the survey, as the widget's own JSON object. Skyra stores it and
        /// hands it back so the widget can continue at the same question. Only its time and session
        /// are read here, and it is never sent to the decision service.
        public var progress: Data?

        public init(
            state: Status,
            lastSync: Int64,
            sessionId: String? = nil,
            progress: Data? = nil
        ) {
            self.state = state
            self.lastSync = lastSync
            self.sessionId = sessionId
            self.progress = progress
        }
    }

    /// A ULID that identifies this visitor to Skyra.
    public var visitorId: String
    /// Entries keyed by full survey slug, `organisation/survey`.
    public var surveys: [String: Survey]

    public init(visitorId: String, surveys: [String: Survey] = [:]) {
        self.visitorId = visitorId
        self.surveys = surveys
    }

    /// Reads the state from JSON in the decision contract's `skyraState` shape.
    /// Throws `SkyraError.invalidState` when the text is not JSON or has no usable visitor ID.
    public init(json: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: json) else {
            throw SkyraError.invalidState
        }

        try self.init(jsonObject: object)
    }

    /// Reads the state from a decoded JSON object in the decision contract's `skyraState` shape.
    /// The visitor ID must be a ULID. A survey entry that is malformed,
    /// or in a state this SDK does not store, is left out instead of failing the whole state.
    public init(jsonObject: Any) throws {
        guard
            let root = jsonObject as? [String: Any],
            let visitorId = root["visitorId"] as? String,
            Identifiers.isValidVisitorID(visitorId)
        else {
            throw SkyraError.invalidState
        }

        self.init(visitorId: visitorId, surveys: Self.surveys(root["surveys"]))
    }

    /// Reads the contract's `surveys` object. A survey entry that is malformed is left out.
    static func surveys(_ value: Any?) -> [String: Survey] {
        var surveys: [String: Survey] = [:]
        for (slug, value) in value as? [String: Any] ?? [:] {
            guard
                Identifiers.isValidSurveySlug(slug),
                let entry = value as? [String: Any],
                let state = (entry["state"] as? String).flatMap(Status.init(rawValue:)),
                let lastSync = Self.milliseconds(entry["lastSync"])
            else {
                continue
            }

            let sessionId = (entry["sessionId"] as? String).flatMap {
                Identifiers.isValidSessionID($0) ? $0 : nil
            }
            surveys[slug] = Survey(
                state: state,
                lastSync: lastSync,
                sessionId: sessionId,
                progress: Self.progressData(entry["progress"])
            )
        }
        return surveys
    }

    // MARK: The widget's store

    /// Reads what a page's `store` holds: `{ "state": …, "progress": { "org/survey": … } }`.
    ///
    /// `state` is what the widget gave `store.state.write`, and `progress` holds what it gave
    /// `store.progress.write` for each survey. A survey with progress is one the visitor is answering, so it
    /// is stored as `Capture` with that progress, unless a later entry says it was finished or closed.
    /// Throws `SkyraError.invalidState` when there is no usable visitor ID.
    public init(widget: Any) throws {
        guard
            let root = widget as? [String: Any],
            let state = root["state"] as? [String: Any],
            let visitorId = state["_id"] as? String,
            Identifiers.isValidVisitorID(visitorId)
        else {
            throw SkyraError.invalidState
        }

        var entries = state
        entries["_id"] = nil
        entries["_l"] = nil
        try self.init(jsonObject: ["visitorId": visitorId, "surveys": entries] as [String: Any])

        for (slug, value) in root["progress"] as? [String: Any] ?? [:] {
            guard
                Identifiers.isValidSurveySlug(slug),
                let progress = Self.progressData(value),
                let object = value as? [String: Any]
            else {
                continue
            }

            let existing = surveys[slug]
            guard let time = Self.milliseconds(object["lastSync"]) ?? existing?.lastSync else {
                continue
            }

            if let existing, existing.state.rank > Status.capture.rank, existing.lastSync >= time {
                continue
            }

            let session = ((object["_owner"] as? [String: Any])?["sessionId"] as? String).flatMap {
                Identifiers.isValidSessionID($0) ? $0 : nil
            }
            surveys[slug] = Survey(
                state: .capture,
                lastSync: max(time, existing?.lastSync ?? 0),
                sessionId: session ?? existing?.sessionId,
                progress: progress
            )
        }
    }

    /// The state as the object a page's `store` reads from:
    /// `{ "state": …, "progress": { "org/survey": … } }`.
    var widgetObject: [String: Any] {
        var state: [String: Any] = ["_id": visitorId]
        var progress: [String: Any] = [:]
        for (slug, survey) in surveys {
            var entry: [String: Any] = ["state": survey.state.rawValue, "lastSync": survey.lastSync]
            if let sessionId = survey.sessionId {
                entry["sessionId"] = sessionId
            }
            state[slug] = entry
            if
                let data = survey.progress,
                let object = try? JSONSerialization.jsonObject(with: data)
            {
                progress[slug] = object
            }
        }
        return ["state": state, "progress": progress]
    }

    // MARK: The decision contract's shape

    /// The state as a JSON object in the decision contract's shape, plus each survey's `progress` for
    /// the widget. `sessionId` and `progress` are left out when there are none.
    public var jsonObject: [String: Any] {
        jsonObject(includingProgress: true)
    }

    /// The decision service accepts only the contract's fields, so its request leaves `progress` out.
    func jsonObject(includingProgress: Bool) -> [String: Any] {
        [
            "visitorId": visitorId,
            "surveys": surveys.mapValues { survey -> [String: Any] in
                var entry: [String: Any] = [
                    "state": survey.state.rawValue,
                    "lastSync": survey.lastSync,
                ]
                if let sessionId = survey.sessionId {
                    entry["sessionId"] = sessionId
                }
                if
                    includingProgress,
                    let progress = survey.progress,
                    let object = try? JSONSerialization.jsonObject(with: progress)
                {
                    entry["progress"] = object
                }
                return entry
            },
        ]
    }

    /// The state as JSON in the decision contract's `skyraState` shape.
    public func json() throws -> Data {
        try JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys])
    }

    /// Merges two copies of one visitor's state. The result is the same whichever side calls it.
    ///
    /// The visitor ID that was created first is kept, so both sides settle on one visitor and the draw
    /// does not change. For each survey the entry with the later time wins. When the times are equal,
    /// the state that is further along wins.
    func merged(with other: SkyraState) -> SkyraState {
        var result = self
        if Self.isCreatedBefore(other.visitorId, visitorId) {
            result.visitorId = other.visitorId
        }
        for (slug, theirs) in other.surveys {
            guard let ours = surveys[slug] else {
                result.surveys[slug] = theirs
                continue
            }

            if theirs.lastSync != ours.lastSync {
                result.surveys[slug] = theirs.lastSync > ours.lastSync ? theirs : ours
            } else if theirs.state != ours.state {
                result.surveys[slug] = theirs.state.rank > ours.state.rank ? theirs : ours
            } else {
                // The same event seen twice. Keep whichever side knows the session.
                result.surveys[slug]?.sessionId = ours.sessionId ?? theirs.sessionId
                // The widget can report two positions within one millisecond. The copy being merged
                // in is the one that arrived last, so its progress is the current one.
                result.surveys[slug]?.progress = theirs.progress ?? ours.progress
            }
        }
        return result
    }

    /// A ULID starts with its creation time, so comparing the text compares the times.
    /// The random part decides between two IDs made in the same millisecond, which keeps the merge symmetric.
    private static func isCreatedBefore(_ first: String, _ second: String) -> Bool {
        first.uppercased() < second.uppercased()
    }

    /// The widget's progress is kept as canonical JSON bytes, so equal progress compares equal.
    /// Anything that is not a JSON object, or is larger than the widget itself accepts, is dropped.
    private static func progressData(_ value: Any?) -> Data? {
        guard
            let object = value as? [String: Any],
            JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(
                withJSONObject: withoutPrototypeKeys(object),
                options: [.sortedKeys]
            ),
            data.count <= maximumProgressBytes
        else {
            return nil
        }

        return data
    }

    static let maximumProgressBytes = 64 * 1024

    /// Leaves out every key named `__proto__`, at any depth. The page gets the progress as a
    /// JavaScript object literal, where that key would replace the object's prototype.
    private static func withoutPrototypeKeys(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            return object.filter { $0.key != "__proto__" }.mapValues(withoutPrototypeKeys)
        }
        if let list = value as? [Any] {
            return list.map(withoutPrototypeKeys)
        }
        return value
    }

    /// Checks stored or incoming progress bytes the same way as progress read from the widget.
    /// Progress that carries its own `lastSync` later than `latest` is dropped as well: handed
    /// back to the widget, it would give the survey's entry a time in the future.
    static func checkedProgress(_ data: Data, latest: Int64) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let time = milliseconds(object["lastSync"]), time > latest {
            return nil
        }
        return progressData(object)
    }

    /// JavaScript sends times as numbers that may arrive as doubles. Booleans and negative or
    /// fractional values are not times.
    private static func milliseconds(_ value: Any?) -> Int64? {
        guard
            let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(),
            number.doubleValue.isFinite,
            number.doubleValue >= 0,
            number.doubleValue <= 9_007_199_254_740_991,
            number.doubleValue == number.doubleValue.rounded()
        else {
            return nil
        }

        return Int64(number.doubleValue)
    }
}
