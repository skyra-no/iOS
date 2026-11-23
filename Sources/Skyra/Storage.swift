// Owns what Skyra keeps on the device: the storage backends, and StateStore's rules for the visitor's state.
// The decision request reads the whole state here; sync writes to it.
import Foundation

/// Atomically read and replace values across instances sharing a namespace.
/// The stored value holds a visitor ID and survey states. It never holds traits or written answers. A survey the visitor is
/// part-way through in a web view also has the widget's progress, which names the options they chose.
public protocol SkyraStorage: AnyObject {
    /// One atomic read-transform-write. Call `transform` exactly once with the stored bytes, store
    /// what it returns (nil removes the key), and return that. It can be called from any thread, so
    /// serialize updates across instances sharing the same namespace.
    func update(key: String, _ transform: (Data?) throws -> Data?) throws -> Data?
}

/// Keeps state in memory for the lifetime of the instance. Used for ephemeral persistence and tests.
public final class SkyraMemoryStorage: SkyraStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    public init() {}

    /// StateStore uses this to replace one in-memory value while holding this backend's lock.
    public func update(key: String, _ transform: (Data?) throws -> Data?) throws -> Data? {
        lock.lock()
        defer {
            lock.unlock()
        }
        let value = try transform(values[key])
        values[key] = value
        return value
    }
}

/// Process-serialized storage. UserDefaults does not support cross-process transactions.
public final class SkyraUserDefaultsStorage: SkyraStorage, @unchecked Sendable {
    private static let lock = NSLock()
    private let defaults: UserDefaults
    private let namespace: String

    /// Skyra or the app chooses the UserDefaults suite and key prefix used for the visitor's state.
    public init(defaults: UserDefaults = .standard, namespace: String = "no.skyra.sdk") {
        self.defaults = defaults
        self.namespace = namespace
    }

    /// StateStore uses this to serialize a read-transform-write across persistent backend instances.
    /// Unchanged bytes are left alone; a nil result deletes the stored value.
    public func update(key: String, _ transform: (Data?) throws -> Data?) throws -> Data? {
        Self.lock.lock()
        defer {
            Self.lock.unlock()
        }
        let key = namespace + "." + key
        let previous = defaults.data(forKey: key)
        let value = try transform(previous)
        if value != previous {
            if let value {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        return value
    }
}

/// Applies Skyra's rules over a raw SkyraStorage backend: one visitor, one entry per survey, and expiry.
/// Every operation is one atomic read-transform-write, so instances sharing a backend never lose updates.
final class StateStore: @unchecked Sendable {
    /// A survey entry is dropped 400 days after its state last changed: longer than the longest
    /// retake time (12 months), so the decision service still sees a finished survey until then.
    static let retentionMilliseconds: Int64 = 400 * 24 * 60 * 60 * 1000
    /// A time this far after the device's clock is still accepted, to allow for clocks that differ.
    /// A later time is not believed: such an entry could never be replaced and would never expire.
    static let futureToleranceMilliseconds: Int64 = 5 * 60 * 1000
    /// The most survey entries kept. Over this, the entries that changed last are the ones kept.
    static let maximumSurveys = 200
    /// The most bytes all progress may take together. Over this, the oldest progress goes first.
    static let maximumTotalProgressBytes = 1024 * 1024
    static let version = 2

    /// Reads the bytes stored under one organisation's key: `{ "version": 2, "state": … }`, with the
    /// state in the decision contract's shape. Nil when they are unreadable or of another version.
    /// A state without a usable visitor ID keeps its surveys and gets a new visitor.
    private static func decode(_ data: Data, now: Int64) -> SkyraState? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            root["version"] as? Int == version,
            let stored = root["state"] as? [String: Any]
        else {
            return nil
        }

        let visitorId = (stored["visitorId"] as? String).flatMap {
            Identifiers.isValidVisitorID($0) ? $0 : nil
        }
        return SkyraState(
            visitorId: visitorId ?? Identifiers.makeULID(now: now),
            surveys: SkyraState.surveys(stored["surveys"])
        )
    }

    /// Sorted keys give the same bytes for the same state.
    private static func encode(_ state: SkyraState) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: ["version": version, "state": state.jsonObject] as [String: Any],
            options: [.sortedKeys]
        )
    }

    let storage: SkyraStorage
    let organization: String
    let key: String
    let clock: () -> Int64

    /// Skyra creates one store per organisation. Tests inject a clock to exercise time boundaries.
    init(storage: SkyraStorage, organization: String, clock: @escaping () -> Int64) {
        self.storage = storage
        self.organization = organization
        key = "state.v\(Self.version).\(organization)"
        self.clock = clock
    }

    /// The visitor's whole state. A first call creates the visitor ID, as the decision contract requires.
    func snapshot() throws -> SkyraState {
        try transaction { _, _ in }
    }

    /// Merges another copy of this visitor's state into the stored one and returns the result.
    /// Entries for other organisations are ignored. Throws `SkyraError.invalidState` when the other
    /// visitor ID is not valid, or claims to be created later than the clock allows.
    func merge(_ other: SkyraState) throws -> SkyraState {
        try transaction { state, now in
            // The device's own ID always passes, even after its clock was set back.
            guard
                other.visitorId == state.visitorId
                || Identifiers.isValidVisitorID(other.visitorId)
                && Identifiers.isVisitorID(other.visitorId, createdBy: Self.latestTime(now))
            else {
                throw SkyraError.invalidState
            }

            var incoming = other
            incoming.surveys = self.pruned(incoming.surveys, now: now)
            state = state.merged(with: incoming)
        }
    }

    /// Decodes the stored state, drops what is no longer valid, applies `body`, and writes the result back.
    /// Unreadable or outdated bytes start a new visitor. A backend that throws surfaces as storageFailure.
    @discardableResult
    private func transaction(_ body: (inout SkyraState, Int64) throws -> Void) throws
        -> SkyraState
    {
        let now = clock()
        var result: SkyraState?
        do {
            _ = try storage.update(key: key) { data in
                var state = data.flatMap { Self.decode($0, now: now) }
                    ?? SkyraState(visitorId: Identifiers.makeULID(now: now))
                state.surveys = self.pruned(state.surveys, now: now)
                try body(&state, now)
                state.surveys = Self.limited(state.surveys)
                result = state
                return try Self.encode(state)
            }
        } catch let error as SkyraError {
            throw error
        } catch {
            throw SkyraError.storageFailure
        }
        // A backend that never called the transform has stored nothing.
        guard let result else {
            throw SkyraError.storageFailure
        }

        return result
    }

    /// The latest time an entry or a visitor ID may carry when the clock reads `now`.
    private static func latestTime(_ now: Int64) -> Int64 {
        let (latest, overflow) = now.addingReportingOverflow(futureToleranceMilliseconds)
        return overflow ? .max : latest
    }

    /// The entries that are still valid at `now`, each with its progress checked again.
    /// Stored and incoming entries both go through here, so stored data that breaks a rule heals.
    private func pruned(
        _ surveys: [String: SkyraState.Survey],
        now: Int64
    ) -> [String: SkyraState.Survey] {
        let latest = Self.latestTime(now)
        var result: [String: SkyraState.Survey] = [:]
        for (slug, survey) in surveys where keeps(survey, slug: slug, now: now, latest: latest) {
            var survey = survey
            // Progress belongs to a survey the visitor is part-way through, and to no other.
            survey.progress = survey.state == .capture
                ? survey.progress.flatMap { SkyraState.checkedProgress($0, latest: latest) }
                : nil
            result[slug] = survey
        }
        return result
    }

    /// An entry is kept while it names a survey of this organisation, has a sane time and session,
    /// changed less than 400 days ago, and is not dated after `latest`.
    private func keeps(
        _ survey: SkyraState.Survey,
        slug: String,
        now: Int64,
        latest: Int64
    ) -> Bool {
        Identifiers.isValidSurveySlug(slug)
            && slug.hasPrefix(organization + "/")
            && survey.lastSync >= 0
            && survey.lastSync > now - Self.retentionMilliseconds
            && survey.lastSync <= latest
            && survey.sessionId.map(Identifiers.isValidSessionID) ?? true
    }

    /// Cuts the entries down to what the store may hold: the entries that changed last, and of
    /// their progress as much as fits, dropping the oldest progress first. The entry itself stays.
    private static func limited(
        _ surveys: [String: SkyraState.Survey]
    ) -> [String: SkyraState.Survey] {
        var bytes = surveys.values.reduce(0) { $0 + ($1.progress?.count ?? 0) }
        guard surveys.count > maximumSurveys || bytes > maximumTotalProgressBytes else {
            return surveys
        }

        // Oldest first. The slug settles equal times, so the same entries go every time.
        var oldestFirst = surveys.sorted {
            ($0.value.lastSync, $0.key) < ($1.value.lastSync, $1.key)
        }
        oldestFirst.removeFirst(max(0, oldestFirst.count - maximumSurveys))
        bytes = oldestFirst.reduce(0) { $0 + ($1.value.progress?.count ?? 0) }
        var result: [String: SkyraState.Survey] = [:]
        for (slug, var survey) in oldestFirst {
            if bytes > maximumTotalProgressBytes, let progress = survey.progress {
                bytes -= progress.count
                survey.progress = nil
            }
            result[slug] = survey
        }
        return result
    }
}
