import XCTest
@testable import Skyra

/// Contract tests for the decision request, its answer, and getSurveys. No test touches the network.
final class DecisionServiceTests: XCTestCase {
    private let visitor = "01JD8ZQ6K3Y7M2N4P5R6S7T8V9"

    // MARK: Request

    func testRequestBodyUsesExactVersionOneKeys() throws {
        let body = try jsonObject(makeRequest(language: "no", locale: "nb-NO").encoded())

        XCTAssertEqual(Set(body.keys), [
            "version",
            "org",
            "type",
            "url",
            "device",
            "timeZone",
            "traits",
            "skyraState",
            "language",
            "locale",
        ])
        XCTAssertEqual(body["version"] as? Int, 1)
        XCTAssertEqual(body["org"] as? String, "org")
        XCTAssertEqual(body["type"] as? String, "inline")
        XCTAssertTrue(body["url"] is NSNull, "url must be an explicit JSON null")
        XCTAssertEqual(body["device"] as? String, "mobile")
        XCTAssertEqual(body["timeZone"] as? String, "Europe/Oslo")
        XCTAssertEqual(body["language"] as? String, "no")
        XCTAssertEqual(body["locale"] as? String, "nb-NO")
        XCTAssertEqual(body["traits"] as? [String: String], ["plan": "premium"])
    }

    func testOptionalLanguageAndLocaleAreOmittedWhenAbsent() throws {
        let body = try jsonObject(makeRequest(language: nil, locale: nil).encoded())

        XCTAssertNil(body["language"])
        XCTAssertNil(body["locale"])
    }

    func testSkyraStateCarriesStateTimeAndSessionForEachSurvey() throws {
        let body = try jsonObject(makeRequest(surveys: [
            "org/completed": .init(
                state: .completed,
                lastSync: 1_794_832_273_590,
                sessionId: Fixture.session
            ),
            "org/selected": .init(state: .selected, lastSync: 1_794_832_000_000),
        ]).encoded())

        let state = try XCTUnwrap(body["skyraState"] as? [String: Any])
        XCTAssertEqual(state["visitorId"] as? String, visitor)
        let surveys = try XCTUnwrap(state["surveys"] as? [String: [String: Any]])
        XCTAssertEqual(Set(surveys.keys), ["org/completed", "org/selected"])
        XCTAssertEqual(surveys["org/completed"]?["state"] as? String, "Completed")
        XCTAssertEqual(surveys["org/completed"]?["lastSync"] as? Int64, 1_794_832_273_590)
        XCTAssertEqual(surveys["org/completed"]?["sessionId"] as? String, Fixture.session)
        XCTAssertEqual(surveys["org/selected"]?["state"] as? String, "Selected")
        XCTAssertNil(surveys["org/selected"]?["sessionId"], "No session until the visitor starts")
    }

    func testOversizedRequestIsRefusedBeforeSending() throws {
        var traits: [String: String] = [:]
        for index in 0 ..< 2000 {
            traits["trait-\(index)"] = String(repeating: "x", count: 40)
        }

        XCTAssertThrowsError(try makeRequest(traits: traits).encoded()) {
            XCTAssertEqual($0 as? SkyraError, .requestTooLarge)
        }
    }

    // MARK: Answer

    func testEverySurveyIsReturnedInTheServiceOrder() throws {
        let surveys = try DecisionService.decode(answer([
            ["slug": "org/first", "language": "no"],
            ["slug": "org/second", "language": "en"],
            ["slug": "org/third", "language": "en", "futureField": true],
        ]), status: 200, organization: "org")

        XCTAssertEqual(surveys, [
            SkyraSurvey(slug: "org/first", language: "no"),
            SkyraSurvey(slug: "org/second", language: "en"),
            SkyraSurvey(slug: "org/third", language: "en"),
        ])
    }

    func testEmptyListMeansNothingToShow() throws {
        XCTAssertEqual(
            try DecisionService.decode(
                answer([]),
                status: 200,
                organization: "org"
            ),
            []
        )
    }

    func testWrongVersionIsRejected() {
        for version in ["2", "\"1\"", "true"] {
            let text = "{\"version\": \(version), \"inline\": []}"
            XCTAssertThrowsError(try DecisionService.decode(
                Data(text.utf8),
                status: 200,
                organization: "org"
            ), version) {
                XCTAssertEqual($0 as? SkyraError, .invalidDecisionResponse)
            }
        }
    }

    func testSurveyOfAnotherOrganizationInvalidatesTheAnswer() {
        for slug in ["other/survey", "organisation/survey"] {
            XCTAssertThrowsError(try DecisionService.decode(
                answer([["slug": "org/ok", "language": "no"], ["slug": slug, "language": "no"]]),
                status: 200,
                organization: "org"
            ), slug) {
                XCTAssertEqual($0 as? SkyraError, .invalidDecisionResponse)
            }
        }
    }

    func testMalformedAnswersFailClosed() {
        let malformed = [
            #"{"version": 1}"#,
            #"{"version": 1, "inline": {"slug": "org/a", "language": "no"}}"#,
            #"{"version": 1, "inline": [{"slug": "org/a"}]}"#,
            #"{"version": 1, "inline": [{"slug": 7, "language": "no"}]}"#,
            #"{"version": 1, "inline": [{"slug": "not-a-slug", "language": "no"}]}"#,
            #"{"version": 1, "inline": [{"slug": "org/a", "language": "no"}, "org/b"]}"#,
            #"not json"#,
        ]
        for text in malformed {
            XCTAssertThrowsError(try DecisionService.decode(
                Data(text.utf8),
                status: 200,
                organization: "org"
            ), text) {
                XCTAssertEqual($0 as? SkyraError, .invalidDecisionResponse)
            }
        }
    }

    func testSurveyWithAnUnusableLanguageInvalidatesTheAnswer() {
        let unusable = [
            "",
            "x",
            "nb_NO",
            "nb NO",
            "<b>",
            "nb\"",
            "nb\n",
            "nø",
            String(repeating: "a", count: 36),
        ]
        for language in unusable {
            XCTAssertThrowsError(try DecisionService.decode(
                answer([
                    ["slug": "org/ok", "language": "no"],
                    ["slug": "org/bad", "language": language],
                ]),
                status: 200,
                organization: "org"
            ), language) {
                XCTAssertEqual($0 as? SkyraError, .invalidDecisionResponse)
            }
        }
    }

    func testSurveyLanguageAtTheLimitsIsAccepted() throws {
        let longest = "zh-Hant-TW"
        let surveys = try DecisionService.decode(answer([
            ["slug": "org/first", "language": "nb"],
            ["slug": "org/second", "language": "en-GB"],
            ["slug": "org/third", "language": longest],
        ]), status: 200, organization: "org")

        XCTAssertEqual(surveys.map(\.language), ["nb", "en-GB", longest])
    }

    func testNonOKStatusIsReportedWithoutReadingTheBody() {
        XCTAssertThrowsError(try DecisionService.decode(
            answer([]),
            status: 404,
            organization: "org"
        )) {
            XCTAssertEqual($0 as? SkyraError, .decisionHTTPStatus(404))
        }
        XCTAssertThrowsError(try DecisionService.decode(
            Data(),
            status: 503,
            organization: "org"
        )) {
            XCTAssertEqual($0 as? SkyraError, .decisionHTTPStatus(503))
        }
    }

    // MARK: User-Agent

    func testUserAgentNamesTheSDKAppAndSystem() {
        XCTAssertEqual(
            DecisionUserAgent.make(
                sdkVersion: "0.1.0",
                appName: "AcmeApp",
                appVersion: "4.2",
                systemName: "iOS",
                systemVersion: "18.1"
            ),
            "Skyra-iOS/0.1.0 (AcmeApp/4.2; iOS 18.1)"
        )
    }

    func testUserAgentFallsBackToUnknownAndKeepsStructureIntact() {
        XCTAssertEqual(
            DecisionUserAgent.make(
                sdkVersion: "0.1.0",
                appName: nil,
                appVersion: "  ",
                systemName: "iOS",
                systemVersion: "18.1"
            ),
            "Skyra-iOS/0.1.0 (unknown/unknown; iOS 18.1)"
        )
        XCTAssertEqual(
            DecisionUserAgent.make(
                sdkVersion: "0.1.0",
                appName: "Acme (Beta); x/y",
                appVersion: "4.2",
                systemName: "iOS",
                systemVersion: "18.1"
            ),
            "Skyra-iOS/0.1.0 (Acme _Beta__ x_y/4.2; iOS 18.1)"
        )
    }

    // MARK: getSurveys

    func testGetSurveysReturnsTheServiceAnswerAndRecordsNothing() async throws {
        let answer = [
            SkyraSurvey(slug: "org/first", language: "no"),
            SkyraSurvey(slug: "org/second", language: "en"),
        ]
        let service = StubDecisionService(answer: answer)
        let sdk = try Fixture.sdk(service: service)

        let first = try await sdk.getSurveys()
        let second = try await sdk.getSurveys()

        XCTAssertEqual(first, answer)
        XCTAssertEqual(second, answer)
        XCTAssertEqual(service.requests.count, 2)
        XCTAssertEqual(
            service.requests[0].state.visitorId,
            service.requests[1].state.visitorId,
            "A visitor keeps one identity"
        )
        XCTAssertTrue(Identifiers.isValidVisitorID(service.requests[0].state.visitorId))
        XCTAssertEqual(try sdk.state().surveys, [:], "Asking records nothing about a survey")
        XCTAssertEqual(service.origins.first, SkyraDefaults.decisionOrigin)
    }

    func testTheServiceAnswerIsReturnedAsItIsWhateverTheStoredState() async throws {
        let surveys = ["new", "done", "closed", "started"].map {
            SkyraSurvey(slug: "org/\($0)", language: "no")
        }
        let sdk = try Fixture.sdk(service: StubDecisionService(answer: surveys))
        try sdk.record(surveys[1], .completed)
        try sdk.record(surveys[2], .rejected)
        try sdk.record(surveys[3], .capture, sessionId: Fixture.session)

        let returned = try await sdk.getSurveys()

        XCTAssertEqual(returned, surveys, "The service decides, not the SDK")
    }

    func testTraitsForTheMomentAreAddedToConfiguredTraitsAndWin() async throws {
        let service = StubDecisionService()
        let sdk = try Fixture.sdk(service: service, configuration: .init(
            organization: "org",
            language: "nb",
            traits: ["plan": "premium", "screen": "start"],
            persistence: .ephemeral
        ))

        _ = try await sdk.getSurveys(traits: ["screen": "checkout"])
        _ = try await sdk.getSurveys()
        _ = try await sdk.getSurveys(traits: ["channel": "web"])
        XCTAssertEqual(
            service.requests[2].traits["channel"],
            "app",
            "The app's channel cannot be replaced"
        )

        XCTAssertEqual(
            service.requests[0].traits,
            ["channel": "app", "plan": "premium", "screen": "checkout"]
        )
        XCTAssertEqual(
            service.requests[1].traits,
            ["channel": "app", "plan": "premium", "screen": "start"]
        )
        XCTAssertEqual(service.requests[0].language, "nb")
        XCTAssertEqual(service.requests[0].organization, "org")
        XCTAssertTrue(service.requests[0].userAgent.hasPrefix("Skyra-iOS/"))
    }

    func testOversizedTraitsAreRefusedBeforeAsking() async throws {
        let service = StubDecisionService()
        let sdk = try Fixture.sdk(service: service)

        for traits in [["": "x"], ["screen": String(repeating: "x", count: 257)]] {
            do {
                _ = try await sdk.getSurveys(traits: traits)
                XCTFail("Expected invalid traits")
            } catch {
                XCTAssertEqual(error as? SkyraError, .invalidTraits)
            }
        }
        XCTAssertEqual(service.requests.count, 0)
    }

    func testTooManyTraitsAreRefusedBeforeAsking() async throws {
        let service = StubDecisionService()
        let sdk = try Fixture.sdk(service: service)

        do {
            _ = try await sdk.getSurveys(traits: numberedTraits(50))
            XCTFail("Expected invalid traits")
        } catch {
            XCTAssertEqual(error as? SkyraError, .invalidTraits)
        }
        XCTAssertEqual(service.requests.count, 0)

        _ = try await sdk.getSurveys(traits: numberedTraits(49))
        XCTAssertEqual(service.requests.count, 1)
    }

    func testPrototypeTraitNameIsRefusedBeforeAsking() async throws {
        let service = StubDecisionService()
        let sdk = try Fixture.sdk(service: service)

        do {
            _ = try await sdk.getSurveys(traits: ["__proto__": "x"])
            XCTFail("Expected invalid traits")
        } catch {
            XCTAssertEqual(error as? SkyraError, .invalidTraits)
        }
        XCTAssertEqual(service.requests.count, 0)
    }

    func testConfiguredTraitLimitsAreEnforced() {
        let refused = [numberedTraits(50), ["__proto__": "x"], ["": "x"]]
        for traits in refused {
            XCTAssertThrowsError(try Fixture.sdk(configuration: .init(
                organization: "org",
                traits: traits,
                persistence: .ephemeral
            ))) {
                XCTAssertEqual($0 as? SkyraError, .invalidConfiguration)
            }
        }
        XCTAssertNoThrow(try Fixture.sdk(configuration: .init(
            organization: "org",
            traits: numberedTraits(49),
            persistence: .ephemeral
        )))
    }

    func testStorageFailureStopsTheRequest() async throws {
        let service = StubDecisionService()
        let sdk = try Fixture.sdk(storage: FailingStorage(), service: service)

        do {
            _ = try await sdk.getSurveys()
            XCTFail("Expected storage failure")
        } catch {
            XCTAssertEqual(error as? SkyraError, .storageFailure)
        }
        XCTAssertEqual(
            service.requests.count,
            0,
            "The service must not decide from state that is not saved"
        )
    }

    // MARK: Helpers

    private func makeRequest(
        language: String? = nil,
        locale: String? = nil,
        traits: [String: String] = ["plan": "premium"],
        surveys: [String: SkyraState.Survey] = [:]
    ) -> DecisionRequest {
        DecisionRequest(
            organization: "org",
            device: "mobile",
            language: language,
            locale: locale,
            timeZone: "Europe/Oslo",
            traits: traits,
            state: SkyraState(visitorId: visitor, surveys: surveys),
            userAgent: "Skyra-iOS/0.1.0 (Test/1.0; iOS 18.1)"
        )
    }

    private func numberedTraits(_ count: Int) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (0 ..< count).map { ("trait-\($0)", "x") })
    }

    private func answer(_ surveys: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "popup": NSNull(),
            "inline": surveys,
            "app": [],
            "rulesVersion": 1,
        ])
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
