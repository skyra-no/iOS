import JavaScriptCore
import XCTest
@testable import Skyra

/// Tests for reading the widget's state and merging it into the device's state.
final class SyncTests: XCTestCase {
    private let now = Fixture.now
    private let survey = Fixture.feedback

    // MARK: Reading the widget's state

    func testReadsTheContractShapeFromJSONTextAndFromAJavaScriptObject() throws {
        let text = """
        {"visitorId":"\(Fixture.olderVisitor)","surveys":{
          "org/feedback":{"state":"Completed","lastSync":1794832273590,"sessionId":"\(Fixture.session)"},
          "org/shown":{"state":"Selected","lastSync":1794832000000}
        },"futureField":true}
        """
        let expected = SkyraState(visitorId: Fixture.olderVisitor, surveys: [
            "org/feedback": .init(
                state: .completed,
                lastSync: 1_794_832_273_590,
                sessionId: Fixture.session
            ),
            "org/shown": .init(state: .selected, lastSync: 1_794_832_000_000),
        ])

        XCTAssertEqual(try SkyraState(json: Data(text.utf8)), expected)

        // WKWebView hands numbers back as doubles.
        let object: [String: Any] = [
            "visitorId": Fixture.olderVisitor,
            "surveys": [
                "org/feedback": [
                    "state": "Completed",
                    "lastSync": 1_794_832_273_590.0,
                    "sessionId": Fixture.session,
                ],
                "org/shown": ["state": "Selected", "lastSync": NSNumber(value: 1_794_832_000_000)],
            ],
        ]
        XCTAssertEqual(try SkyraState(jsonObject: object), expected)
    }

    func testEntriesTheSDKCannotUseAreLeftOut() throws {
        let object: [String: Any] = [
            "visitorId": Fixture.olderVisitor,
            "surveys": [
                "org/ok": ["state": "Rejected", "lastSync": 5],
                "org/lost-draw": ["state": "NotSelected", "lastSync": 5],
                "org/unknown-state": ["state": "Paused", "lastSync": 5],
                "org/no-time": ["state": "Completed"],
                "org/boolean-time": ["state": "Completed", "lastSync": true],
                "org/negative-time": ["state": "Completed", "lastSync": -1],
                "org/fractional-time": ["state": "Completed", "lastSync": 1.5],
                "not-a-slug": ["state": "Completed", "lastSync": 5],
                "org/legacy": "Completed",
                "org/bad-session": ["state": "Capture", "lastSync": 5, "sessionId": "has space"],
            ] as [String: Any],
        ]

        let state = try SkyraState(jsonObject: object)

        XCTAssertEqual(Set(state.surveys.keys), ["org/ok", "org/bad-session"])
        XCTAssertNil(state.surveys["org/bad-session"]?.sessionId, "An unusable session is dropped")
    }

    func testStateWithoutAUsableVisitorIsRefused() {
        let unusable: [Any] = [
            ["surveys": [:] as [String: Any]],
            ["visitorId": "not-a-ulid", "surveys": [:] as [String: Any]],
            ["visitorId": 7],
            ["a", "list"],
            "text",
        ]
        for object in unusable {
            XCTAssertThrowsError(try SkyraState(jsonObject: object)) {
                XCTAssertEqual($0 as? SkyraError, .invalidState)
            }
        }
        XCTAssertThrowsError(try SkyraState(json: Data("not json".utf8))) {
            XCTAssertEqual($0 as? SkyraError, .invalidState)
        }
    }

    func testStateRoundTripsThroughJSON() throws {
        let state = SkyraState(visitorId: Fixture.olderVisitor, surveys: [
            "org/feedback": .init(state: .capture, lastSync: now, sessionId: Fixture.session),
            "org/shown": .init(state: .selected, lastSync: now),
        ])

        XCTAssertEqual(try SkyraState(json: state.json()), state)
        XCTAssertEqual(try SkyraState(jsonObject: state.jsonObject), state)
    }

    // MARK: Merging

    func testSyncAddsWhatTheWidgetKnowsAndKeepsWhatTheDeviceKnows() throws {
        let sdk = try Fixture.sdk()
        try sdk.record(survey, .completed)
        let device = try sdk.state()

        let merged = try sdk.sync(SkyraState(visitorId: device.visitorId, surveys: [
            "org/web": .init(state: .rejected, lastSync: now - 5000, sessionId: Fixture.session),
        ]))

        XCTAssertEqual(merged.surveys, [
            survey.slug: .init(state: .completed, lastSync: now),
            "org/web": .init(state: .rejected, lastSync: now - 5000, sessionId: Fixture.session),
        ])
        XCTAssertEqual(try sdk.state(), merged, "The merged state is stored")
    }

    func testTheLaterEntryWinsForEachSurvey() throws {
        let clock = TestClock(now)
        let sdk = try Fixture.sdk(clock: clock)
        try sdk.record(survey, .selected)
        let other = SkyraSurvey(slug: "org/other", language: "en")
        try sdk.record(other, .completed)
        let visitor = try sdk.state().visitorId
        clock.advance(10000)

        let merged = try sdk.sync(SkyraState(visitorId: visitor, surveys: [
            survey.slug: .init(state: .completed, lastSync: now + 5000, sessionId: Fixture.session),
            other.slug: .init(state: .rejected, lastSync: now - 5000),
        ]))

        XCTAssertEqual(
            merged.surveys[survey.slug],
            .init(state: .completed, lastSync: now + 5000, sessionId: Fixture.session),
            "The widget's later completion replaces the device's earlier Selected"
        )
        XCTAssertEqual(
            merged.surveys[other.slug],
            .init(state: .completed, lastSync: now),
            "The device's later completion survives the widget's earlier close"
        )
    }

    func testEqualTimesKeepTheStateThatIsFurtherAlongAndTheKnownSession() throws {
        let sdk = try Fixture.sdk()
        try sdk.record(survey, .selected)
        let closed = SkyraSurvey(slug: "org/closed", language: "en")
        try sdk.record(closed, .rejected)
        let started = SkyraSurvey(slug: "org/started", language: "en")
        try sdk.record(started, .capture)
        let visitor = try sdk.state().visitorId

        let merged = try sdk.sync(SkyraState(visitorId: visitor, surveys: [
            survey.slug: .init(state: .capture, lastSync: now, sessionId: Fixture.session),
            closed.slug: .init(state: .capture, lastSync: now),
            started.slug: .init(state: .capture, lastSync: now, sessionId: Fixture.session),
        ]))

        XCTAssertEqual(merged.surveys[survey.slug]?.state, .capture)
        XCTAssertEqual(merged.surveys[closed.slug]?.state, .rejected)
        XCTAssertEqual(merged.surveys[started.slug]?.sessionId, Fixture.session)
    }

    func testTheVisitorCreatedFirstIsKeptOnBothSides() throws {
        let sdk = try Fixture.sdk()
        let device = try sdk.state().visitorId

        XCTAssertEqual(
            try sdk.sync(SkyraState(visitorId: Fixture.olderVisitor)).visitorId,
            Fixture.olderVisitor,
            "The widget's visitor was created first, so the device adopts it"
        )
        XCTAssertEqual(try sdk.state().visitorId, Fixture.olderVisitor)

        let newer = Identifiers.makeULID(now: now + 1000)
        XCTAssertEqual(try sdk.sync(SkyraState(visitorId: newer)).visitorId, Fixture.olderVisitor)
        XCTAssertNotEqual(device, Fixture.olderVisitor)
    }

    func testMergeGivesTheSameResultFromEitherSide() {
        let device = SkyraState(visitorId: Identifiers.makeULID(now: now), surveys: [
            "org/a": .init(state: .selected, lastSync: 10),
            "org/b": .init(state: .completed, lastSync: 20, sessionId: "device"),
            "org/c": .init(state: .rejected, lastSync: 30),
            "org/only-device": .init(state: .capture, lastSync: 40),
        ])
        let widget = SkyraState(visitorId: Fixture.olderVisitor, surveys: [
            "org/a": .init(state: .capture, lastSync: 15, sessionId: "widget"),
            "org/b": .init(state: .rejected, lastSync: 5),
            "org/c": .init(state: .capture, lastSync: 30),
            "org/only-widget": .init(state: .completed, lastSync: 50),
        ])

        let merged = device.merged(with: widget)

        XCTAssertEqual(merged, widget.merged(with: device))
        XCTAssertEqual(merged.merged(with: widget), merged, "Syncing again changes nothing")
        XCTAssertEqual(merged.visitorId, Fixture.olderVisitor)
        XCTAssertEqual(merged.surveys["org/a"]?.sessionId, "widget")
        XCTAssertEqual(merged.surveys["org/b"]?.sessionId, "device")
        XCTAssertEqual(merged.surveys["org/c"]?.state, .rejected)
        XCTAssertEqual(merged.surveys.count, 5)
    }

    func testSyncIgnoresOtherOrganizationsAndEntriesOlderThan400Days() throws {
        let sdk = try Fixture.sdk()
        let visitor = try sdk.state().visitorId

        let merged = try sdk.sync(SkyraState(visitorId: visitor, surveys: [
            "other/survey": .init(state: .completed, lastSync: now),
            "organisation/survey": .init(state: .completed, lastSync: now),
            "org/expired": .init(
                state: .completed,
                lastSync: now - StateStore.retentionMilliseconds
            ),
            "org/recent": .init(
                state: .completed,
                lastSync: now - StateStore.retentionMilliseconds + 1
            ),
        ]))

        XCTAssertEqual(Array(merged.surveys.keys), ["org/recent"])
    }

    func testSyncRefusesAnInvalidVisitorAndReportsStorageFailure() throws {
        let sdk = try Fixture.sdk()
        try sdk.record(survey, .selected)
        let before = try sdk.state()

        XCTAssertThrowsError(try sdk.sync(SkyraState(visitorId: "not-a-ulid", surveys: [
            "org/web": .init(state: .completed, lastSync: now),
        ]))) {
            XCTAssertEqual($0 as? SkyraError, .invalidState)
        }
        XCTAssertEqual(try sdk.state(), before, "A refused sync changes nothing")

        let failing = try Fixture.sdk(storage: FailingStorage())
        XCTAssertThrowsError(try failing.sync(SkyraState(visitorId: Fixture.olderVisitor))) {
            XCTAssertEqual($0 as? SkyraError, .storageFailure)
        }
    }

    func testSyncIgnoresEntriesDatedAfterTheClockAllows() throws {
        let sdk = try Fixture.sdk()
        try sdk.record(survey, .selected)
        let visitor = try sdk.state().visitorId
        let tolerance = StateStore.futureToleranceMilliseconds

        let merged = try sdk.sync(SkyraState(visitorId: visitor, surveys: [
            survey.slug: .init(state: .completed, lastSync: now + tolerance + 1),
            "org/far": .init(state: .completed, lastSync: 9_007_199_254_740_991),
            "org/ahead": .init(state: .completed, lastSync: now + tolerance),
        ]))

        XCTAssertEqual(merged.surveys, [
            survey.slug: .init(state: .selected, lastSync: now),
            "org/ahead": .init(state: .completed, lastSync: now + tolerance),
        ])
    }

    func testProgressDatedAfterTheClockAllowsIsIgnored() throws {
        let sdk = try Fixture.sdk()
        let late = now + StateStore.futureToleranceMilliseconds + 1

        // The widget's progress sets its entry's time, so the whole entry is ignored.
        let fromWidget = try sdk.sync(SkyraState(widget: [
            "state": ["_id": Fixture.olderVisitor],
            "progress": [
                "org/late": ["currentCard": 1, "lastSync": late],
                "org/ahead": ["currentCard": 1, "lastSync": late - 1],
            ],
        ] as [String: Any]))
        XCTAssertEqual(Array(fromWidget.surveys.keys), ["org/ahead"])

        // An entry with a sane time keeps its place, without the progress.
        let merged = try sdk.sync(SkyraState(visitorId: Fixture.olderVisitor, surveys: [
            "org/late": .init(
                state: .capture,
                lastSync: now,
                progress: Data(#"{"currentCard":1,"lastSync":\#(late)}"#.utf8)
            ),
        ]))
        XCTAssertEqual(merged.surveys["org/late"], .init(state: .capture, lastSync: now))
    }

    func testASurveySlugThatIsTooLongIsSkipped() throws {
        let longest = "org/" + String(repeating: "a", count: Identifiers.maximumSlugLength)
        let tooLong = longest + "a"

        let state = try SkyraState(jsonObject: [
            "visitorId": Fixture.olderVisitor,
            "surveys": [
                longest: ["state": "Completed", "lastSync": now],
                tooLong: ["state": "Completed", "lastSync": now],
            ],
        ] as [String: Any])
        XCTAssertEqual(Array(state.surveys.keys), [longest])

        let sdk = try Fixture.sdk()
        let merged = try sdk.sync(SkyraState(visitorId: Fixture.olderVisitor, surveys: [
            longest: .init(state: .completed, lastSync: now),
            tooLong: .init(state: .completed, lastSync: now),
        ]))
        XCTAssertEqual(Array(merged.surveys.keys), [longest])
    }

    func testOnlyTheLatestEntriesAreKeptWhenThereAreTooMany() throws {
        let sdk = try Fixture.sdk()
        try sdk.record(survey, .completed)
        let visitor = try sdk.state().visitorId
        var surveys: [String: SkyraState.Survey] = [:]
        for index in 1 ... StateStore.maximumSurveys {
            surveys["org/survey-\(index)"] = .init(state: .selected, lastSync: now - Int64(index))
        }

        let merged = try sdk.sync(SkyraState(visitorId: visitor, surveys: surveys))

        XCTAssertEqual(merged.surveys.count, StateStore.maximumSurveys)
        XCTAssertNotNil(merged.surveys[survey.slug], "The device's entry is the latest")
        XCTAssertNil(merged.surveys["org/survey-\(StateStore.maximumSurveys)"], "The oldest goes")
        XCTAssertNotNil(merged.surveys["org/survey-\(StateStore.maximumSurveys - 1)"])
        XCTAssertEqual(try sdk.state(), merged)
    }

    func testProgressOverTheTotalLimitIsDroppedFromTheOldestEntries() throws {
        let sdk = try Fixture.sdk()
        let blob = Data(
            (#"{"text":""# + String(repeating: "a", count: 63 * 1024) + #""}"#).utf8
        )
        let fits = StateStore.maximumTotalProgressBytes / blob.count
        var surveys: [String: SkyraState.Survey] = [:]
        for index in 0 ..< fits {
            surveys["org/survey-\(index)"] = .init(
                state: .capture,
                lastSync: now - Int64(index),
                progress: blob
            )
        }
        XCTAssertEqual(
            try sdk.sync(SkyraState(visitorId: Fixture.olderVisitor, surveys: surveys)).surveys,
            surveys,
            "Progress up to the limit is kept"
        )

        let merged = try sdk.sync(SkyraState(visitorId: Fixture.olderVisitor, surveys: [
            "org/one-more": .init(state: .capture, lastSync: now - 2, progress: blob),
        ]))

        let oldest = "org/survey-\(fits - 1)"
        XCTAssertEqual(merged.surveys.count, fits + 1, "No entry is dropped")
        XCTAssertNotNil(merged.surveys[oldest])
        XCTAssertNil(merged.surveys[oldest]?.progress, "The oldest entry stays without progress")
        XCTAssertEqual(merged.surveys.values.filter { $0.progress != nil }.count, fits)
        XCTAssertEqual(merged.surveys["org/one-more"]?.progress, blob)
        XCTAssertEqual(try sdk.state(), merged)
    }

    func testAVisitorWithNoCreationTimeIsRefused() throws {
        let zero = "0000000000" + Fixture.olderVisitor.dropFirst(10)
        XCTAssertFalse(Identifiers.isValidVisitorID(zero))
        XCTAssertTrue(Identifiers.isValidVisitorID("0000000001" + zero.dropFirst(10)))

        XCTAssertThrowsError(try SkyraState(jsonObject: ["visitorId": zero])) {
            XCTAssertEqual($0 as? SkyraError, .invalidState)
        }
        XCTAssertThrowsError(try SkyraState(widget: ["state": ["_id": zero]])) {
            XCTAssertEqual($0 as? SkyraError, .invalidState)
        }
        let sdk = try Fixture.sdk()
        let before = try sdk.state()
        XCTAssertThrowsError(try sdk.sync(SkyraState(visitorId: zero))) {
            XCTAssertEqual($0 as? SkyraError, .invalidState)
        }
        XCTAssertEqual(try sdk.state(), before)
    }

    func testAVisitorCreatedAfterTheClockAllowsIsRefused() throws {
        let clock = TestClock(now)
        let sdk = try Fixture.sdk(clock: clock)
        try sdk.record(survey, .selected)
        let before = try sdk.state()
        let tolerance = StateStore.futureToleranceMilliseconds

        let late = SkyraState(visitorId: Identifiers.makeULID(now: now + tolerance + 1), surveys: [
            "org/web": .init(state: .completed, lastSync: now),
        ])
        XCTAssertThrowsError(try sdk.sync(late)) {
            XCTAssertEqual($0 as? SkyraError, .invalidState)
        }
        XCTAssertEqual(try sdk.state(), before, "A refused sync changes nothing")

        let ahead = SkyraState(visitorId: Identifiers.makeULID(now: now + tolerance))
        XCTAssertEqual(try sdk.sync(ahead).visitorId, before.visitorId)

        // The device's own visitor still syncs after its clock was set back.
        clock.advance(-Fixture.year)
        XCTAssertEqual(
            try sdk.sync(SkyraState(visitorId: before.visitorId)).visitorId,
            before.visitorId
        )
    }

    func testTheNextDecisionCarriesTheSyncedState() async throws {
        let service = StubDecisionService()
        let sdk = try Fixture.sdk(service: service)
        let widget = SkyraState(visitorId: Fixture.olderVisitor, surveys: [
            "org/web": .init(state: .completed, lastSync: now - 1000, sessionId: Fixture.session),
        ])

        try sdk.sync(widget)
        _ = try await sdk.getSurveys()

        XCTAssertEqual(service.requests.last?.state, widget)
    }

    // MARK: Progress

    func testProgressIsStoredAndHandedBackButNeverSentToTheDecisionService() async throws {
        let service = StubDecisionService()
        let sdk = try Fixture.sdk(service: service)
        let progress: [String: Any] = [
            "currentCard": 2,
            "history": [0, 1],
            "variables": ["singleSelect": ["a1": "b2"]],
        ]
        let widget = try SkyraState(jsonObject: [
            "visitorId": Fixture.olderVisitor,
            "surveys": [
                "org/feedback": [
                    "state": "Capture",
                    "lastSync": now,
                    "sessionId": Fixture.session,
                    "progress": progress,
                ] as [String: Any],
            ],
        ] as [String: Any])

        try sdk.sync(widget)

        let stored = try sdk.state()
        XCTAssertEqual(stored, widget)
        let entry = try XCTUnwrap(
            (stored.jsonObject["surveys"] as? [String: [String: Any]])?["org/feedback"]
        )
        XCTAssertEqual(entry["progress"] as? NSDictionary, progress as NSDictionary)
        XCTAssertEqual(try SkyraState(json: stored.json()), stored)

        _ = try await sdk.getSurveys()
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(service.requests.last).encoded())
                as? [String: Any]
        )
        let sent = try XCTUnwrap(
            ((body["skyraState"] as? [String: Any])?["surveys"] as? [String: [String: Any]])?[
                "org/feedback"
            ]
        )
        XCTAssertNil(sent["progress"])
        XCTAssertEqual(sent["sessionId"] as? String, Fixture.session)
    }

    func testProgressThatIsNotAnObjectOrIsTooLargeIsDropped() throws {
        func progress(_ value: Any) throws -> Data? {
            try SkyraState(jsonObject: [
                "visitorId": Fixture.olderVisitor,
                "surveys": [
                    "org/feedback": ["state": "Capture", "lastSync": now, "progress": value]
                        as [String: Any],
                ],
            ] as [String: Any]).surveys["org/feedback"]?.progress
        }

        XCTAssertNil(try progress("card 2"))
        XCTAssertNil(try progress([1, 2]))
        XCTAssertNil(
            try progress(["text": String(repeating: "a", count: SkyraState.maximumProgressBytes)])
        )
        XCTAssertNotNil(try progress(["currentCard": 0]))
    }

    func testPrototypeKeysAreLeftOutOfProgressAtAnyDepth() throws {
        let unsafe = #"{"__proto__":{"a":1},"cards":[{"__proto__":{"b":2},"id":1}],"#
            + #""variables":{"__proto__":null,"plan":"x"}}"#
        let safe = Data(#"{"cards":[{"id":1}],"variables":{"plan":"x"}}"#.utf8)

        let contract = #"{"visitorId":"\#(Fixture.olderVisitor)","surveys":{"org/feedback":"#
            + #"{"state":"Capture","lastSync":\#(now),"progress":\#(unsafe)}}}"#
        XCTAssertEqual(
            try SkyraState(json: Data(contract.utf8)).surveys["org/feedback"]?.progress,
            safe
        )

        let entry = #"{"state":"Capture","lastSync":\#(now)}"#
        let widget = #"{"state":{"_id":"\#(Fixture.olderVisitor)","org/feedback":\#(entry)},"progress":"#
            + #"{"org/feedback":\#(unsafe)}}"#
        XCTAssertEqual(
            try SkyraState(widget: JSONSerialization.jsonObject(with: Data(widget.utf8)))
                .surveys["org/feedback"]?.progress,
            safe
        )

        // Progress an app passes in as bytes is checked when it is stored.
        let sdk = try Fixture.sdk()
        try sdk.sync(SkyraState(visitorId: Fixture.olderVisitor, surveys: [
            "org/feedback": .init(state: .capture, lastSync: now, progress: Data(unsafe.utf8)),
        ]))
        XCTAssertEqual(try sdk.state().surveys["org/feedback"]?.progress, safe)
        XCTAssertFalse(try sdk.widgetConfig().contains("__proto__"))
    }

    func testALaterEntryReplacesProgress() throws {
        let sdk = try Fixture.sdk()
        let first = Data(#"{"currentCard":1}"#.utf8)
        try sdk.sync(SkyraState(visitorId: Fixture.olderVisitor, surveys: [
            "org/feedback": .init(
                state: .capture,
                lastSync: now,
                sessionId: Fixture.session,
                progress: first
            ),
        ]))
        try sdk.sync(SkyraState(visitorId: Fixture.olderVisitor, surveys: [
            "org/feedback": .init(state: .completed, lastSync: now + 1, sessionId: Fixture.session),
        ]))

        XCTAssertNil(try sdk.state().surveys["org/feedback"]?.progress)
    }

    func testProgressReportedTwiceInOneMillisecondKeepsTheLastOne() throws {
        let sdk = try Fixture.sdk()
        for card in [1, 2] {
            try sdk.sync(SkyraState(visitorId: Fixture.olderVisitor, surveys: [
                "org/feedback": .init(
                    state: .capture,
                    lastSync: now,
                    sessionId: Fixture.session,
                    progress: Data(#"{"currentCard":\#(card)}"#.utf8)
                ),
            ]))
        }

        XCTAssertEqual(
            try sdk.state().surveys["org/feedback"]?.progress,
            Data(#"{"currentCard":2}"#.utf8)
        )
    }

    // MARK: The widget's store

    func testWhatTheWidgetSavesIsStoredAndHandedBackUnchanged() throws {
        let sdk = try Fixture.sdk()
        let progress: [String: Any] = [
            "currentCard": 2,
            "history": [0, 1],
            "lastSync": now + 5,
            "_owner": ["visitorId": Fixture.olderVisitor, "sessionId": Fixture.session],
        ]
        let widget: [String: Any] = [
            "state": [
                "_id": Fixture.olderVisitor,
                "_l": "nb",
                "org/done": ["state": "Completed", "lastSync": now, "sessionId": Fixture.session],
            ] as [String: Any],
            "progress": ["org/feedback": progress],
        ]

        let stored = try sdk.sync(SkyraState(widget: widget))

        XCTAssertEqual(stored.visitorId, Fixture.olderVisitor)
        XCTAssertEqual(stored.surveys["org/done"]?.state, .completed)
        XCTAssertEqual(stored.surveys["org/feedback"]?.state, .capture)
        XCTAssertEqual(stored.surveys["org/feedback"]?.lastSync, now + 5)
        XCTAssertEqual(stored.surveys["org/feedback"]?.sessionId, Fixture.session)

        let handedBack = try sdk.state().widgetObject
        let state = try XCTUnwrap(handedBack["state"] as? [String: Any])
        XCTAssertEqual(state["_id"] as? String, Fixture.olderVisitor)
        XCTAssertEqual((state["org/done"] as? [String: Any])?["state"] as? String, "Completed")
        XCTAssertEqual(
            (handedBack["progress"] as? [String: Any])?["org/feedback"] as? NSDictionary,
            progress as NSDictionary
        )
        XCTAssertEqual(try SkyraState(widget: handedBack), stored)
    }

    func testFinishingASurveyEndsItsProgress() throws {
        let sdk = try Fixture.sdk()
        let progress: [String: Any] = ["currentCard": 1, "lastSync": now]
        try sdk.sync(SkyraState(widget: [
            "state": ["_id": Fixture.olderVisitor],
            "progress": ["org/feedback": progress],
        ] as [String: Any]))
        // The widget clears the progress and then saves how the survey ended.
        try sdk.sync(SkyraState(widget: [
            "state": ["_id": Fixture.olderVisitor],
            "progress": [:] as [String: Any],
        ] as [String: Any]))
        XCTAssertEqual(try sdk.state().surveys["org/feedback"]?.state, .capture)

        let finished: [String: Any] = ["state": "Completed", "lastSync": now + 1]
        // Progress that is older than the end does not reopen the survey.
        try sdk.sync(SkyraState(widget: [
            "state": ["_id": Fixture.olderVisitor, "org/feedback": finished] as [String: Any],
            "progress": ["org/feedback": progress],
        ] as [String: Any]))

        let entry = try XCTUnwrap(try sdk.state().surveys["org/feedback"])
        XCTAssertEqual(entry.state, .completed)
        XCTAssertNil(entry.progress)
        XCTAssertNil((try sdk.state().widgetObject["progress"] as? [String: Any])?["org/feedback"])
    }

    func testWidgetStateWithoutAVisitorIsRefused() {
        for widget: Any in [
            ["state": NSNull(), "progress": [:] as [String: Any]] as [String: Any],
            ["state": ["_id": "nope"]],
            "text",
        ] {
            XCTAssertThrowsError(try SkyraState(widget: widget)) {
                XCTAssertEqual($0 as? SkyraError, .invalidState)
            }
        }
    }

    func testWidgetConfigCarriesTheVisitorTheTraitsAndAStoreThatPostsBack() async throws {
        let sdk = try Fixture.sdk(configuration: .init(
            organization: "org",
            traits: ["plan": "premium", "channel": "web"],
            persistence: .ephemeral
        ))
        try sdk.sync(SkyraState(widget: [
            "state": ["_id": Fixture.olderVisitor],
            "progress": ["org/feedback": ["currentCard": 1, "lastSync": now, "note": "</script>"]],
        ] as [String: Any]))

        XCTAssertTrue(
            try sdk.widgetConfig().contains(#""traits":{"channel":"app","plan":"premium"}"#)
        )
        _ = try await sdk.getSurveys(traits: ["screen": "checkout"])
        let script = try sdk.widgetConfig()

        XCTAssertTrue(script.contains(#""org":"org""#))
        XCTAssertTrue(
            script.contains(#""traits":{"channel":"app","plan":"premium","screen":"checkout"}"#)
        )
        XCTAssertTrue(script.contains(#""_id":"\#(Fixture.olderVisitor)""#))
        XCTAssertTrue(script.contains(#""org\/feedback":{"currentCard":1"#))
        XCTAssertTrue(script.contains("window.webkit.messageHandlers.skyra.postMessage(saved)"))
        XCTAssertFalse(script.contains("</script>"), "Stored data must not end the script element")
    }

    func testWidgetConfigRunsAndWhatItPostsSyncsBack() throws {
        let sdk = try Fixture.sdk()
        let visitor = try sdk.state().visitorId
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(
            "var posted = null; var window = { webkit: { messageHandlers: { skyra: "
                + "{ postMessage: value => { posted = JSON.stringify(value) } } } } }"
        )

        context.evaluateScript(try sdk.widgetConfig())
        XCTAssertNil(context.exception)
        context.evaluateScript("""
        const store = window.SKYRA_CONFIG.store
        const state = store.state.read()
        state["org/feedback"] = { state: "Completed", lastSync: \(now), sessionId: "\(Fixture.session)" }
        store.progress.write("org/other", { currentCard: 3, lastSync: \(now) })
        store.state.write(state)
        """)
        XCTAssertNil(context.exception)

        let posted = try XCTUnwrap(context.objectForKeyedSubscript("posted").toString())
        let stored = try sdk.sync(
            SkyraState(widget: JSONSerialization.jsonObject(with: Data(posted.utf8)))
        )

        XCTAssertEqual(stored.visitorId, visitor)
        XCTAssertEqual(stored.surveys["org/feedback"]?.state, .completed)
        XCTAssertEqual(stored.surveys["org/other"]?.state, .capture)
        XCTAssertEqual(
            context.evaluateScript(
                #"window.SKYRA_CONFIG.store.progress.read("org/other").currentCard"#
            )
            .toInt32(),
            3
        )
    }
}
