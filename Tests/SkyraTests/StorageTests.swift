// Tests native survey storage against a controllable clock, memory backends, and isolated UserDefaults suites.
import XCTest
@testable import Skyra

/// XCTest scenarios for identity, restoration, privacy filtering, retention, and atomic writes.
final class StorageTests: XCTestCase {
    let now: Int64 = 1_789_391_234_567
    let origin = Origin(URL(string: "https://survey.skyra.no")!)!
    let visitor = "01ARZ3NDEKTSV4RRFFQ69G5FAV"

    /// Exercise the actual allocation-to-bridge path, including distinct sessions in one millisecond.
    func testFreshOutgoingIdentitiesAreULIDs() throws {
        let store = StateStore(storage: SkyraMemoryStorage(), origin: origin, clock: { self.now })
        var sessions: Set<String> = []
        var visitors: Set<String> = []
        for _ in 0 ..< 100 {
            let identity = try store.prepare(slug: "org/survey", resume: true)
            let json = try Initialization(
                visitorId: identity.0,
                sessionId: identity.1,
                language: nil,
                device: "mobile",
                traits: [:],
                savedState: identity.2
            ).json()
            let payload =
                try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            for field in ["visitorId", "sessionId"] {
                let value = try XCTUnwrap(payload[field] as? String)
                XCTAssertNotNil(value.range(
                    of: "^[0-7][0-9A-HJKMNP-TV-Z]{25}$",
                    options: .regularExpression
                ))
                XCTAssertNil(UUID(uuidString: value))
                let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
                let timestamp = value.prefix(10).reduce(Int64(0)) { result, character in
                    result * 32 + Int64(alphabet.firstIndex(of: character)!)
                }
                XCTAssertEqual(timestamp, now)
            }
            XCTAssertTrue(payload["savedState"] is NSNull)
            XCTAssertTrue(sessions.insert(identity.1).inserted)
            visitors.insert(identity.0)
        }
        XCTAssertEqual(visitors.count, 1)
    }

    /// Both old UUID and new ULID sessions keep their identity, progress, and deadlines across instances.
    func testUUIDAndULIDSessionsResumeUnchangedThenRetakeWithULID() throws {
        for session in ["82F58CA1-35C9-498F-9454-A48A3E962718", "01ARZ3NDEKTSV4RRFFQ69G5FAW"] {
            let storage = SkyraMemoryStorage()
            let store = StateStore(storage: storage, origin: origin, clock: { self.now })
            let input = try state(session: session)
            try store.save(input)
            let bytes = try storage.update(key: origin.key) { $0 }
            let reopened = StateStore(storage: storage, origin: origin, clock: { self.now + 1000 })
            let resumed = try reopened.prepare(slug: "org/survey", resume: true)
            XCTAssertEqual(resumed.0, input.visitorId)
            XCTAssertEqual(resumed.1, session)
            XCTAssertEqual(resumed.2, input)
            // JSONEncoder may reorder object keys when re-encoding an unchanged envelope.
            // Compare all stored values, including identity, progress, and expiry, rather than bytes.
            let before = try JSONSerialization.jsonObject(with: XCTUnwrap(bytes)) as? NSDictionary
            let after = try JSONSerialization.jsonObject(
                with: XCTUnwrap(storage.update(key: origin.key) { $0 })
            ) as? NSDictionary
            XCTAssertNotNil(before)
            XCTAssertEqual(after, before)
            let json = try Initialization(
                visitorId: resumed.0,
                sessionId: resumed.1,
                language: nil,
                device: "mobile",
                traits: [:],
                savedState: resumed.2
            ).json()
            let payload =
                try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            XCTAssertEqual(payload["sessionId"] as? String, session)
            let saved = try XCTUnwrap(payload["savedState"] as? [String: Any])
            XCTAssertEqual(saved["sessionId"] as? String, session)
            XCTAssertEqual(saved["sessionInitialized"] as? Bool, true)

            let fresh = try reopened.prepare(slug: "org/survey", resume: false)
            XCTAssertTrue(Identifiers.isValidVisitorID(fresh.1))
            XCTAssertNotEqual(fresh.1, session)
            XCTAssertNil(fresh.2)
            for status in [SkyraSavedState.Status.completed, .rejected] {
                try reopened.terminal(
                    slug: "org/survey",
                    visitor: visitor,
                    session: session,
                    status: status
                )
                XCTAssertEqual(try reopened.history(slug: "org/survey")?.status, status)
                let retake = try reopened.prepare(slug: "org/survey", resume: true)
                XCTAssertTrue(Identifiers.isValidVisitorID(retake.1))
                XCTAssertNotEqual(retake.1, session)
                XCTAssertNil(retake.2)
            }
        }
    }

    /// Timestamp bounds must not overflow ULID's 128-bit representation.
    func testULIDTimestampBounds() {
        for (time, prefix): (Int64, String) in [
            (-1, "0000000000"),
            (0, "0000000000"),
            (0xFFFF_FFFF_FFFF, "7ZZZZZZZZZ"),
            (Int64.max, "7ZZZZZZZZZ"),
        ] {
            let value = Identifiers.makeULID(now: time)
            XCTAssertTrue(Identifiers.isValidVisitorID(value))
            XCTAssertEqual(String(value.prefix(10)), prefix)
        }
    }

    /// A failed final-status write must keep eligibility closed until the terminal outcome is saved successfully.
    func testStorageFailureFailsAutomaticSelectionClosedEvenAfterReadRecovery() throws {
        final class Fallible: SkyraStorage {
            let memory = SkyraMemoryStorage()
            var failing = true
            /// StateStore calls this backend; the scenario toggles read/write failure around a real memory store.
            func update(key: String, _ transform: (Data?) throws -> Data?) throws -> Data? {
                if failing {
                    throw SkyraError.storageFailure
                }
                return try memory.update(key: key, transform)
            }
        }
        let storage = Fallible()
        let store = StateStore(storage: storage, origin: origin, clock: { self.now })
        XCTAssertThrowsError(try store.history(slug: "org/survey"))
        XCTAssertThrowsError(try store.terminal(
            slug: "org/survey",
            visitor: visitor,
            session: "s",
            status: .rejected
        ))
        storage.failing = false
        XCTAssertThrowsError(try store.history(slug: "org/survey"))
        try store.terminal(slug: "org/survey", visitor: visitor, session: "s", status: .rejected)
        XCTAssertEqual(try store.history(slug: "org/survey")?.status, .rejected)
    }

    /// Policy history reads must preserve both storage bytes and retention deadlines, including expired records.
    func testHistoryReadsDoNotAllocateOrSlide() throws {
        var clock = now
        let storage = SkyraMemoryStorage()
        let store = StateStore(storage: storage, origin: origin, clock: { clock })
        XCTAssertNil(try store.history(slug: "org/survey"))
        XCTAssertNil(try storage.update(key: origin.key) { $0 })
        try store.save(state())
        try store.terminal(
            slug: "org/survey",
            visitor: visitor,
            session: "stable-session",
            status: .rejected
        )
        let bytes = try storage.update(key: origin.key) { $0 }
        XCTAssertEqual(try store.history(slug: "org/survey")?.updatedAt, now)
        clock += 59_999
        XCTAssertEqual(try store.history(slug: "org/survey")?.updatedAt, now)
        clock += 1
        XCTAssertEqual(try store.history(slug: "org/survey")?.updatedAt, now)
        XCTAssertEqual(try storage.update(key: origin.key) { $0 }, bytes)
        let shared = StateStore(storage: storage, origin: origin, clock: { clock })
        XCTAssertEqual(try shared.history(slug: "org/survey")?.status, .rejected)
        XCTAssertNil(try shared.history(slug: "other/survey"))
        XCTAssertNil(try StateStore(
            storage: SkyraMemoryStorage(),
            origin: origin
        ).history(slug: "org/survey"))
        clock = now + SkyraSavedState.retentionMilliseconds
        XCTAssertNil(try shared.history(slug: "org/survey"))
        XCTAssertEqual(try storage.update(key: origin.key) { $0 }, bytes)
    }

    /// Terminal history remains available for cooldowns while completion/rejection removes resumable progress.
    func testHistoryIncludesCompletionAndRejectionWithoutResumableProgress() throws {
        let store = StateStore(storage: SkyraMemoryStorage(), origin: origin, clock: { self.now })
        try store.save(state(status: "Completed"))
        XCTAssertEqual(try store.history(slug: "org/survey")?.status, .completed)
        try store.terminal(
            slug: "org/survey",
            visitor: visitor,
            session: "new-session",
            status: .rejected
        )
        XCTAssertEqual(try store.history(slug: "org/survey")?.status, .rejected)
        XCTAssertNil(try store.prepare(slug: "org/survey", resume: true).2)
    }

    /// Build a valid hosted snapshot for storage, bridge, eligibility, and presentation tests; overrides exercise
    /// timestamps/status boundaries and extra JSON fields without changing the fixture's stable identity.
    func state(
        slug: String = "org/survey",
        status: String = "Capture",
        session: String = "stable-session",
        updated: Int64? = nil,
        extra: String = ""
    ) throws -> SkyraSavedState {
        let time = updated ?? now
        return try JSONDecoder().decode(SkyraSavedState.self, from: Data("""
        {"version":1,"slug":"\(slug)","surveyId":"82F58CA1-35C9-498F-9454-A48A3E962718","revision":2,
         "visitorId":"\(visitor)","sessionId":"\(session)","sessionInitialized":true,
         "updatedAt":\(time),"expiresAt":\(time + SkyraSavedState.retentionMilliseconds),
         "skyraState":{"state":"\(status)","language":"en"},
         "progress":{"currentCard":2,"history":[0,1],"variables":{"singleSelect":{"card1":"answer1"}\(extra)}}}
        """.utf8))
    }

    /// Restoration must preserve exact integer timestamps and expire at the original one-year boundary.
    func testExactMillisecondsAndNoReadRenewal() throws {
        var clock = now
        let store = StateStore(storage: SkyraMemoryStorage(), origin: origin, clock: { clock })
        let input = try state()
        try store.save(input)
        clock += 789
        let restored = try XCTUnwrap(store.prepare(slug: "org/survey", resume: true).2)
        XCTAssertEqual(restored, input)
        let json = String(decoding: try JSONEncoder().encode(restored), as: UTF8.self)
        XCTAssertTrue(json.contains("1789391234567"))
        clock = now + SkyraSavedState.retentionMilliseconds - 1
        XCTAssertNotNil(try store.prepare(slug: "org/survey", resume: true).2)
        clock += 1
        XCTAssertNil(try store.prepare(slug: "org/survey", resume: true).2)
    }

    /// Fresh requests replace the session; terminal outcomes clear active progress while retaining status history.
    func testFreshTerminalAndDismissal() throws {
        let store = StateStore(storage: SkyraMemoryStorage(), origin: origin, clock: { self.now })
        try store.save(state())
        let resumed = try store.prepare(slug: "org/survey", resume: true)
        XCTAssertEqual(resumed.0, visitor)
        XCTAssertEqual(resumed.1, "stable-session")
        let fresh = try store.prepare(slug: "org/survey", resume: false)
        XCTAssertNil(fresh.2)
        XCTAssertNotEqual(fresh.1, resumed.1)
        try store.terminal(
            slug: "org/survey",
            visitor: visitor,
            session: resumed.1,
            status: .rejected
        )
        let record = try XCTUnwrap(store.transaction { _ in }.surveys["org/survey"])
        XCTAssertEqual(record.status, .rejected)
        XCTAssertNil(record.active)
        XCTAssertNil(try store.prepare(slug: "org/survey", resume: true).2)
        try store.save(state(status: "Completed"))
        XCTAssertNil(try store.prepare(slug: "org/survey", resume: true).2)
        XCTAssertEqual(try store.transaction { _ in }.surveys["org/survey"]?.status, .completed)
    }

    /// Persisting a decoded snapshot must discard unknown typed-answer fields while keeping selection IDs.
    func testPrivacyAllowlistStripsUnknownAnswers() throws {
        let input =
            try state(
                extra: ",\"freeText\":\"secret typed answer\",\"recruitment\":{\"email\":\"private@example.com\"}"
            )
        let storage = SkyraMemoryStorage()
        let store = StateStore(storage: storage, origin: origin, clock: { self.now })
        try store.save(input)
        let data = try XCTUnwrap(storage.update(key: origin.key) { $0 })
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("secret"))
        XCTAssertFalse(text.contains("email"))
        XCTAssertFalse(text.contains("freeText"))
        XCTAssertTrue(text.contains("answer1"))
    }

    /// Persistent instances share updates within an origin, while other origins and ephemeral stores stay isolated.
    func testPersistentInstancesMergeAndOriginsAreIsolated() throws {
        let suite = "SkyraTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
        }
        let a = StateStore(
            storage: SkyraUserDefaultsStorage(defaults: defaults),
            origin: origin,
            clock: { self.now }
        )
        let b = StateStore(
            storage: SkyraUserDefaultsStorage(defaults: defaults),
            origin: origin,
            clock: { self.now }
        )
        try a.save(state())
        try b.save(state(slug: "other/survey"))
        XCTAssertEqual(try a.transaction { _ in }.surveys.count, 2)
        let other = StateStore(
            storage: SkyraUserDefaultsStorage(defaults: defaults),
            origin: Origin(URL(string: "http://localhost:5173")!)!,
            clock: { self.now }
        )
        XCTAssertTrue(try other.transaction { _ in }.surveys.isEmpty)
        try a.terminal(slug: "org/survey", visitor: visitor, session: "rejected", status: .rejected)
        let fresh = StateStore(
            storage: SkyraUserDefaultsStorage(defaults: defaults),
            origin: origin,
            clock: { self.now }
        )
        XCTAssertEqual(try fresh.history(slug: "org/survey")?.status, .rejected)
        XCTAssertNil(try other.history(slug: "org/survey"))
        let memory = StateStore(storage: SkyraMemoryStorage(), origin: origin, clock: { self.now })
        XCTAssertTrue(try memory.transaction { _ in }.surveys.isEmpty)
    }

    /// Corrupt storage must recover safely; snapshots outside valid timestamp and expiry boundaries are rejected.
    func testCorruptionAndValidationBoundaries() throws {
        let storage = SkyraMemoryStorage()
        _ = try storage.update(key: origin.key) { _ in Data("invalid".utf8) }
        let store = StateStore(storage: storage, origin: origin, clock: { self.now })
        XCTAssertTrue(Identifiers.isValidVisitorID(try store.prepare(
            slug: "org/survey",
            resume: true
        ).0))
        XCTAssertThrowsError(try state(updated: now + 1).validate(now: now))
        XCTAssertThrowsError(try state(updated: now -
                SkyraSavedState.retentionMilliseconds).validate(now: now))
        XCTAssertNoThrow(try state(updated: now - SkyraSavedState.retentionMilliseconds +
                1).validate(now: now))
        let valid = try JSONEncoder().encode(state())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        object["expiresAt"] = now + SkyraSavedState.retentionMilliseconds + 1
        let invalid = try JSONDecoder().decode(
            SkyraSavedState.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertThrowsError(try invalid.validate(now: now))
    }

    /// Rotating an expired visitor must not erase independently younger resumable survey records.
    func testVisitorExpiryDoesNotEraseYoungerSurveyRecords() throws {
        var clock = now
        let store = StateStore(storage: SkyraMemoryStorage(), origin: origin, clock: { clock })
        let original = try store.prepare(slug: "org/survey", resume: true).0
        clock += 1000
        try store.save(state(updated: clock))
        clock = now + SkyraSavedState.retentionMilliseconds
        XCTAssertNotEqual(try store.prepare(slug: "other/survey", resume: false).0, original)
        XCTAssertNotNil(try store.prepare(slug: "org/survey", resume: true).2)
    }

    /// Recording the same terminal outcome twice must retain its first timestamp and original expiry.
    func testTerminalReadsAndDuplicateAcknowledgmentDoNotExtendExpiry() throws {
        for status in [SkyraSavedState.Status.completed, .rejected] {
            var clock = now
            let store = StateStore(storage: SkyraMemoryStorage(), origin: origin, clock: { clock })
            try store.terminal(
                slug: "org/survey",
                visitor: visitor,
                session: "stable-session",
                status: status
            )
            clock += 1000
            try store.terminal(
                slug: "org/survey",
                visitor: visitor,
                session: "stable-session",
                status: status
            )
            let record = try XCTUnwrap(store.transaction { _ in }.surveys["org/survey"])
            XCTAssertEqual(record.updatedAt, now)
            XCTAssertEqual(record.expiresAt, now + SkyraSavedState.retentionMilliseconds)
        }
    }

    /// Concurrent instances sharing UserDefaults must merge survey updates rather than overwrite each other.
    func testConcurrentPersistentInstancesDoNotLoseSurveyUpdates() throws {
        let suite = "SkyraConcurrency.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            defaults.removePersistentDomain(forName: suite)
        }
        let states = try (0 ..< 20).map { try state(slug: "org/survey\($0)") }
        DispatchQueue.concurrentPerform(iterations: states.count) { index in
            let store = StateStore(
                storage: SkyraUserDefaultsStorage(defaults: defaults),
                origin: origin,
                clock: { self.now }
            )
            try? store.save(states[index])
        }
        let store = StateStore(
            storage: SkyraUserDefaultsStorage(defaults: defaults),
            origin: origin,
            clock: { self.now }
        )
        XCTAssertEqual(try store.transaction { _ in }.surveys.count, states.count)
    }
}
