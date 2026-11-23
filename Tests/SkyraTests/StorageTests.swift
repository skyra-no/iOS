import XCTest
@testable import Skyra

/// Tests for what is kept on the device: the visitor, the survey entries, and when they go away.
final class StorageTests: XCTestCase {
    private let now = Fixture.now
    private let survey = Fixture.feedback

    func testVisitorIsAULIDCreatedOnceAndKept() throws {
        let clock = TestClock(now)
        let sdk = try Fixture.sdk(clock: clock)

        let visitor = try sdk.state().visitorId
        XCTAssertTrue(Identifiers.isValidVisitorID(visitor))
        XCTAssertEqual(
            String(visitor.prefix(10)),
            String(Identifiers.makeULID(now: now).prefix(10)),
            "The ULID starts with its creation time"
        )

        clock.advance(10 * Fixture.year)
        XCTAssertEqual(try sdk.state().visitorId, visitor, "The visitor ID does not expire")
    }

    func testULIDTimestampBounds() {
        XCTAssertTrue(Identifiers.makeULID(now: -1).hasPrefix("0000000001"))
        XCTAssertTrue(Identifiers.makeULID(now: 0).hasPrefix("0000000001"))
        XCTAssertTrue(Identifiers.isValidVisitorID(Identifiers.makeULID(now: 0)))
        XCTAssertTrue(Identifiers.makeULID(now: Int64.max).hasPrefix("7ZZZZZZZZZ"))
        XCTAssertTrue(Identifiers.isValidVisitorID(Identifiers.makeULID(now: Int64.max)))
    }

    func testAVisitorOnAClockThatReadsZeroIsKept() throws {
        let sdk = try Fixture.sdk(clock: TestClock(0))

        let visitor = try sdk.state().visitorId

        XCTAssertEqual(try sdk.state().visitorId, visitor)
        XCTAssertEqual(try sdk.sync(SkyraState(visitorId: visitor)).visitorId, visitor)
    }

    func testStateSurvivesANewInstanceOnTheSameStorage() throws {
        let storage = SkyraMemoryStorage()
        let first = try Fixture.sdk(storage: storage)
        try first.record(survey, .completed)

        let second = try Fixture.sdk(storage: storage)

        XCTAssertEqual(try second.state(), try first.state())
        XCTAssertEqual(try second.state().surveys[survey.slug]?.state, .completed)
    }

    func testOrganizationsDoNotShareState() throws {
        let storage = SkyraMemoryStorage()
        let org = try Fixture.sdk(storage: storage)
        let other = try Fixture.sdk(storage: storage, configuration: .init(
            organization: "other",
            persistence: .ephemeral
        ))
        try org.record(survey, .completed)

        XCTAssertEqual(try other.state().surveys, [:])
        XCTAssertNotEqual(try other.state().visitorId, try org.state().visitorId)
    }

    func testEphemeralInstancesStartEmptyAndPersistentOnesUseUserDefaults() throws {
        let first = try Skyra(configuration: .init(
            organization: "org",
            persistence: .ephemeral
        ))
        try first.record(survey, .completed)
        let second = try Skyra(configuration: .init(
            organization: "org",
            persistence: .ephemeral
        ))
        XCTAssertEqual(try second.state().surveys, [:])

        let suite = "no.skyra.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
        }
        let saved = try Skyra(
            configuration: .init(organization: "org"),
            storage: SkyraUserDefaultsStorage(defaults: defaults)
        )
        try saved.record(survey, .completed)
        let reopened = try Skyra(
            configuration: .init(organization: "org"),
            storage: SkyraUserDefaultsStorage(defaults: defaults)
        )
        XCTAssertEqual(try reopened.state(), try saved.state())
        XCTAssertNotNil(defaults.data(forKey: "no.skyra.sdk.state.v2.org"))
    }

    func testSurveyEntryIsDropped400DaysAfterItLastChanged() throws {
        let clock = TestClock(now)
        let sdk = try Fixture.sdk(clock: clock)
        try sdk.record(survey, .completed)

        clock.advance(StateStore.retentionMilliseconds - 1)
        XCTAssertNotNil(try sdk.state().surveys[survey.slug])

        clock.advance(1)
        XCTAssertNil(try sdk.state().surveys[survey.slug])
    }

    func testUnreadableOrOutdatedBytesStartANewVisitor() throws {
        let key = "state.v2.org"
        let stale = #"{"version":1,"state":{"visitorId":"\#(Fixture.olderVisitor)","surveys":{}}}"#
        for bytes in ["not json", "{}", stale] {
            let storage = SkyraMemoryStorage()
            _ = try storage.update(key: key) { _ in Data(bytes.utf8) }
            let sdk = try Fixture.sdk(storage: storage)

            let state = try sdk.state()
            XCTAssertTrue(Identifiers.isValidVisitorID(state.visitorId), bytes)
            XCTAssertNotEqual(state.visitorId, Fixture.olderVisitor, bytes)
            XCTAssertEqual(state.surveys, [:], bytes)
        }
    }

    func testStoredEntriesThatAreNotValidAreDropped() throws {
        let storage = SkyraMemoryStorage()
        let stored = """
        {"version":2,"state":{"visitorId":"\(Fixture.olderVisitor)","surveys":{
          "org/kept":{"state":"Completed","lastSync":\(now - 1000),"sessionId":"\(Fixture.session)"},
          "other/foreign":{"state":"Completed","lastSync":\(now - 1000)},
          "org/negative":{"state":"Completed","lastSync":-1},
          "org/bad-session":{"state":"Capture","lastSync":\(now - 1000),"sessionId":"has space"}
        }}}
        """
        _ = try storage.update(key: "state.v2.org") { _ in Data(stored.utf8) }
        let sdk = try Fixture.sdk(storage: storage)

        let state = try sdk.state()
        XCTAssertEqual(state.visitorId, Fixture.olderVisitor)
        XCTAssertEqual(Set(state.surveys.keys), ["org/kept", "org/bad-session"])
        XCTAssertNil(state.surveys["org/bad-session"]?.sessionId, "An unusable session is left out")
    }

    func testOneUnreadableStoredEntryDoesNotLoseTheRest() throws {
        let storage = SkyraMemoryStorage()
        let stored = """
        {"version":2,"state":{"visitorId":"\(Fixture.olderVisitor)","surveys":{
          "org/kept":{"state":"Completed","lastSync":\(now - 1000)},
          "org/unknown":{"state":"Paused","lastSync":\(now - 1000)},
          "org/fraction":{"state":"Completed","lastSync":1.5},
          "org/text":"Completed"
        }}}
        """
        _ = try storage.update(key: "state.v2.org") { _ in Data(stored.utf8) }
        let sdk = try Fixture.sdk(storage: storage)

        let state = try sdk.state()
        XCTAssertEqual(state.visitorId, Fixture.olderVisitor)
        XCTAssertEqual(Array(state.surveys.keys), ["org/kept"])
    }

    func testAStoredVisitorThatIsNotValidIsReplacedAndTheSurveysStay() throws {
        let storage = SkyraMemoryStorage()
        let stored = """
        {"version":2,"state":{"visitorId":"not-a-ulid","surveys":{
          "org/kept":{"state":"Completed","lastSync":\(now - 1000)}
        }}}
        """
        _ = try storage.update(key: "state.v2.org") { _ in Data(stored.utf8) }
        let sdk = try Fixture.sdk(storage: storage)

        let state = try sdk.state()
        XCTAssertTrue(Identifiers.isValidVisitorID(state.visitorId))
        XCTAssertEqual(Array(state.surveys.keys), ["org/kept"])
    }

    func testTheStoredStateReadsBackAsTheSameState() throws {
        let storage = SkyraMemoryStorage()
        let sdk = try Fixture.sdk(storage: storage)
        let merged = try sdk.sync(SkyraState(visitorId: Fixture.olderVisitor, surveys: [
            "org/open": .init(
                state: .capture,
                lastSync: now,
                sessionId: Fixture.session,
                progress: Data(#"{"currentCard":1}"#.utf8)
            ),
        ]))

        let bytes = try XCTUnwrap(try storage.update(key: "state.v2.org") { $0 })
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])

        XCTAssertEqual(root["version"] as? Int, 2)
        XCTAssertEqual(try SkyraState(jsonObject: XCTUnwrap(root["state"])), merged)
        XCTAssertEqual(try SkyraState(json: merged.json()), merged)
    }

    func testAStoredEntryDatedInTheFutureIsDroppedSoTheSurveyCanChangeAgain() throws {
        let storage = SkyraMemoryStorage()
        let tolerance = StateStore.futureToleranceMilliseconds
        let stored = """
        {"version":2,"state":{"visitorId":"\(Fixture.olderVisitor)","surveys":{
          "org/feedback":{"state":"Completed","lastSync":\(now + tolerance + 1)},
          "org/far":{"state":"Completed","lastSync":9007199254740991},
          "org/ahead":{"state":"Selected","lastSync":\(now + tolerance)}
        }}}
        """
        _ = try storage.update(key: "state.v2.org") { _ in Data(stored.utf8) }
        let sdk = try Fixture.sdk(storage: storage)

        XCTAssertEqual(Array(try sdk.state().surveys.keys), ["org/ahead"])

        try sdk.record(survey, .selected)
        XCTAssertEqual(try sdk.state().surveys[survey.slug], .init(state: .selected, lastSync: now))
    }

    func testStoredStateOverTheLimitsIsCutDownWhenRead() throws {
        let blob = ["text": String(repeating: "a", count: 63 * 1024)]
        var surveys: [String: Any] = [
            "org/" + String(repeating: "a", count: 200): ["state": "Selected", "lastSync": now],
            "org/future-progress": [
                "state": "Capture",
                "lastSync": now,
                "progress": ["lastSync": now + Fixture.year],
            ] as [String: Any],
        ]
        for index in 0 ..< 220 {
            var entry: [String: Any] = ["state": "Capture", "lastSync": now - Int64(index)]
            if index < 20 {
                entry["progress"] = blob
            }
            surveys["org/survey-\(index)"] = entry
        }
        let stored = try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "state": ["visitorId": Fixture.olderVisitor, "surveys": surveys] as [String: Any],
        ] as [String: Any])
        let storage = SkyraMemoryStorage()
        _ = try storage.update(key: "state.v2.org") { _ in stored }
        let sdk = try Fixture.sdk(storage: storage)

        let state = try sdk.state()

        XCTAssertEqual(state.surveys.count, StateStore.maximumSurveys)
        XCTAssertFalse(state.surveys.keys.contains { $0.count > 200 }, "The long slug is dropped")
        XCTAssertNil(state.surveys["org/survey-199"], "Only the latest entries are kept")
        XCTAssertNotNil(state.surveys["org/survey-198"])
        let kept = try XCTUnwrap(state.surveys["org/future-progress"])
        XCTAssertNil(kept.progress, "Progress dated in the future goes; its entry stays")
        XCTAssertEqual(
            Set(state.surveys.filter { $0.value.progress != nil }.keys),
            Set((0 ..< 16).map { "org/survey-\($0)" }),
            "The latest progress that fits in the total is kept"
        )
        XCTAssertEqual(try sdk.state(), state, "Reading again changes nothing")
    }

    func testStorageFailureIsReported() throws {
        let sdk = try Fixture.sdk(storage: FailingStorage())

        XCTAssertThrowsError(try sdk.state()) {
            XCTAssertEqual($0 as? SkyraError, .storageFailure)
        }
    }

    func testConcurrentInstancesDoNotLoseUpdates() throws {
        let storage = SkyraMemoryStorage()
        let instances = try (0 ..< 8).map { _ in try Fixture.sdk(storage: storage) }

        DispatchQueue.concurrentPerform(iterations: 200) { index in
            let survey = SkyraSurvey(slug: "org/survey-\(index)", language: "en")
            try? instances[index % instances.count].record(survey, .completed)
        }

        let state = try instances[0].state()
        XCTAssertEqual(state.surveys.count, 200)
        XCTAssertTrue(try instances.allSatisfy { try $0.state().visitorId == state.visitorId })
    }
}
