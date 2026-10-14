// Owns native survey persistence: raw storage backends plus StateStore's identity and retention rules.
// Presentation reads history/restoration here; SurveyController writes progress and final outcomes.
import Foundation

/// Atomically read and replace values across instances sharing a namespace.
/// Supplied native records contain no typed answers or traits.
public protocol SkyraStorage: AnyObject {
    /// StateStore calls this for an atomic read-transform-write. Return the stored bytes; nil removes
    /// the key. Implementations must serialize updates across instances sharing the same namespace.
    func update(key: String, _ transform: (Data?) throws -> Data?) throws -> Data?
}

/// The SDK creates a new memory store for each ephemeral instance.
public final class SkyraMemoryStorage: SkyraStorage {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    /// Skyra or the app creates an empty, instance-local backend for ephemeral persistence.
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
public final class SkyraUserDefaultsStorage: SkyraStorage {
    private static let lock = NSLock()
    private let defaults: UserDefaults
    private let namespace: String

    /// Skyra or the app chooses the UserDefaults suite and prefix used for durable survey records.
    public init(defaults: UserDefaults = .standard, namespace: String = "no.skyra.sdk.v1") {
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

/// One survey's status and expiry, with resumable progress only while it is in Capture state.
struct NativeRecord: Codable {
    let visitorId: String
    let sessionId: String
    let status: SkyraSavedState.Status
    let updatedAt: Int64
    let expiresAt: Int64
    let active: SkyraSavedState?
}

/// Applies survey-specific rules over a raw SkyraStorage backend: identity, restoration, and expiry.
/// A class keeps failure bookkeeping and its lock shared across calls from the SDK and popup controller.
final class StateStore {
    /// All records for one hosted origin, encoded atomically under a single backend key.
    struct Envelope: Codable {
        var version = 1
        var visitorId: String
        var visitorExpiresAt: Int64
        var surveys: [String: NativeRecord] = [:]
    }

    let storage: SkyraStorage
    let key: String
    let clock: () -> Int64
    private var failedTerminals: Set<String> = []
    private let failureLock = NSLock()

    /// Skyra creates this for its hosted origin. Tests inject a clock to exercise retention boundaries.
    init(
        storage: SkyraStorage,
        origin: Origin,
        clock: @escaping () -> Int64 = Clock.nowMilliseconds
    ) {
        self.storage = storage
        key = origin.key
        self.clock = clock
    }

    /// Internal writes use this to decode, prune, apply a change, and atomically encode the envelope.
    /// It allocates or rotates visitor identity as needed; read-only eligibility uses history instead.
    @discardableResult
    func transaction(_ body: (inout Envelope) throws -> Void) throws -> Envelope {
        let now = clock()
        var result: Envelope?
        _ = try storage.update(key: key) { data in
            var envelope = data.flatMap { try? JSONDecoder().decode(Envelope.self, from: $0) }
            if envelope?.version != 1 {
                envelope = Envelope(
                    visitorId: Identifiers.makeULID(now: now),
                    visitorExpiresAt: now + SkyraSavedState.retentionMilliseconds
                )
            }
            var value = envelope!
            if
                !Identifiers.isValidVisitorID(value.visitorId) || value.visitorExpiresAt <= now ||
                value.visitorExpiresAt > now + SkyraSavedState.retentionMilliseconds
            {
                value.visitorId = Identifiers.makeULID(now: now)
                value.visitorExpiresAt = now + SkyraSavedState.retentionMilliseconds
            }
            value.surveys = value.surveys.filter { Self.valid($0.value, slug: $0.key, now: now) }
            try body(&value)
            result = value
            return try JSONEncoder().encode(value)
        }
        return result!
    }

    /// transaction and history call this before trusting a record's identity, expiry, and active progress.
    private static func valid(_ record: NativeRecord, slug: String, now: Int64) -> Bool {
        guard
            record.expiresAt > now, record.updatedAt >= 0, record.updatedAt <= now,
            record.expiresAt - record.updatedAt == SkyraSavedState.retentionMilliseconds,
            Identifiers.isValidVisitorID(record.visitorId),
            Identifiers.isValidSessionID(record.sessionId),
            Identifiers.isValidSurveySlug(slug)
        else {
            return false
        }

        if let active = record.active {
            return record.status == .capture && active.skyraState.state == .capture &&
                active.slug ==
                slug &&
                active.visitorId == record.visitorId && active.sessionId == record.sessionId &&
                active.updatedAt == record.updatedAt && active.expiresAt == record.expiresAt &&
                (try? active.validate(now: now)) != nil
        }
        return record.status != .capture
    }

    /// Presentation calls this after eligibility succeeds. Return visitor ID, session ID, and optional
    /// saved progress; resuming keeps the original identity while a fresh request creates a new session.
    /// Legacy UUID sessions remain recoverable; rewriting them would split an existing interaction.
    func prepare(slug: String, resume: Bool) throws -> (String, String, SkyraSavedState?) {
        let envelope = try transaction { _ in }
        if resume, let state = envelope.surveys[slug]?.active {
            return (
                state.visitorId,
                state.sessionId,
                state
            )
        }
        return (envelope.visitorId, Identifiers.makeULID(now: clock()), nil)
    }

    /// Presentation reads prior history here before evaluating policy. This does not allocate identity,
    /// prune records, or renew expiry; a failed terminal write keeps subsequent requests closed.
    func history(slug: String) throws -> NativeRecord? {
        failureLock.lock()
        let failed = failedTerminals.contains(slug)
        failureLock.unlock()
        if failed {
            throw SkyraError.storageFailure
        }

        let now = clock()
        var result: NativeRecord?
        do {
            _ = try storage.update(key: key) { data in
                if
                    let data, let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
                    envelope.version == 1, let record = envelope.surveys[slug], Self.valid(
                        record,
                        slug: slug,
                        now: now
                    )
                {
                    result = record
                }
                return data
            }
        } catch {
            throw SkyraError.storageFailure
        }
        return result
    }

    /// SurveyController calls this for a validated state event. Persist the snapshot and retain active
    /// progress only for Capture; completed/rejected history has nothing to resume.
    func save(_ state: SkyraSavedState) throws {
        try state.validate(now: clock())
        try transaction { envelope in
            envelope.surveys[state.slug] = NativeRecord(
                visitorId: state.visitorId,
                sessionId: state.sessionId,
                status: state.skyraState.state,
                updatedAt: state.updatedAt,
                expiresAt: state.expiresAt,
                active: state.skyraState.state == .capture ? state : nil
            )
        }
    }

    /// SurveyController calls this on completion or rejection to record the outcome and clear progress.
    /// Duplicate outcomes for the same session keep their original expiry instead of extending it.
    func terminal(
        slug: String,
        visitor: String,
        session: String,
        status: SkyraSavedState.Status
    ) throws {
        let now = clock()
        failureLock.lock()
        failedTerminals.insert(slug)
        failureLock.unlock()
        try transaction { envelope in
            let old = envelope.surveys[slug]
            let retain = old?.sessionId == session && old?.status == status
            envelope.surveys[slug] = NativeRecord(
                visitorId: visitor,
                sessionId: session,
                status: status,
                updatedAt: retain ? old!.updatedAt : now,
                expiresAt: retain ? old!.expiresAt : now + SkyraSavedState.retentionMilliseconds,
                active: nil
            )
        }
        failureLock.lock()
        failedTerminals.remove(slug)
        failureLock.unlock()
    }
}
