import XCTest
@testable import Skyra

@MainActor
final class SurveySelectionTests: XCTestCase {
    func testExplicitSlugSkipsListButUsesEligibility() async throws {
        let sdk = try Skyra(configuration: .init(persistence: .ephemeral))
        sdk.loadSurveyList = { _, _ in XCTFail("Explicit slug must skip discovery")
            return nil
        }
        sdk.loadPolicy = { _, slug in
            XCTAssertEqual(slug, "other/explicit")
            return PresentationPolicy(
                capturePercent: 0,
                minTimeForRetake: nil,
                minTimeForRetrigger: nil
            )
        }
        let result = try await sdk.resolvePresentationDecision(slug: "other/explicit")
        XCTAssertEqual(result, .notShown(.captureNotSelected))
        XCTAssertNil(try sdk.store.storage.update(key: sdk.store.key) { $0 })
    }

    func testNilSlugRequiresOrganizationBeforeCallingDecision() async throws {
        let sdk = try Skyra(configuration: .init(persistence: .ephemeral, surveyDecision: { _ in
            XCTFail("Missing organization must fail before decision")
            return .notShown(.unavailable)
        }))
        do {
            _ = try await sdk.resolvePresentationDecision(slug: nil)
            XCTFail("Expected missing organization")
        } catch {
            XCTAssertEqual(error as? SkyraError, .missingOrganization)
        }
    }

    func testCustomDecisionReceivesRequestContextOnce() async throws {
        var calls = 0
        let sdk = try Skyra(configuration: .init(
            persistence: .ephemeral,
            organization: "org",
            surveyDecision: { context in
                calls += 1
                XCTAssertEqual(context.organization, "org")
                XCTAssertNil(context.requestedSlug)
                return .present(slug: "org/selected")
            }
        ))
        sdk.loadSurveyList = { _, _ in XCTFail("Custom decision replaces discovery")
            return nil
        }
        sdk.loadPolicy = { _, _ in XCTFail("Custom decision replaces eligibility")
            return nil
        }
        let result = try await sdk.resolvePresentationDecision(slug: nil)
        XCTAssertEqual(result, .present(slug: "org/selected"))
        XCTAssertEqual(calls, 1)
    }

    func testCustomNoShowAndErrorsArePreserved() async throws {
        let sdk = try Skyra(configuration: .init(
            persistence: .ephemeral,
            organization: "org",
            surveyDecision: { _ in .notShown(.rejectedCooldown) }
        ))
        let result = try await sdk.resolvePresentationDecision(slug: nil)
        XCTAssertEqual(result, .notShown(.rejectedCooldown))
        let failing = try Skyra(configuration: .init(
            persistence: .ephemeral,
            organization: "org",
            surveyDecision: { _ in throw SkyraError.storageFailure }
        ))
        do {
            _ = try await failing.resolvePresentationDecision(slug: nil)
            XCTFail("Decision errors must propagate")
        } catch {
            XCTAssertEqual(error as? SkyraError, .storageFailure)
        }
    }

    func testCustomSlugMustBeValidAndBelongToOrganization() async throws {
        for selected in ["invalid", "other/survey"] {
            let sdk = try Skyra(configuration: .init(
                persistence: .ephemeral,
                organization: "org",
                surveyDecision: { _ in .present(slug: selected) }
            ))
            do {
                _ = try await sdk.resolvePresentationDecision(slug: nil)
                XCTFail("Invalid or cross-organization slug must fail")
            } catch {
                XCTAssertEqual(error as? SkyraError, .invalidSlug)
            }
        }
    }

    func testListDecoderChoosesFirstAppInResponseOrder() throws {
        XCTAssertEqual(try decode([
            ["renderType": "Popup", "fullSlug": "org/popup"],
            ["renderType": "App", "fullSlug": "org/first"],
            ["renderType": "App", "fullSlug": "org/second"],
        ]), "org/first")
    }

    func testListDecoderReturnsNoneForEmptyOrNoAppList() throws {
        XCTAssertNil(try decode([]))
        XCTAssertNil(try decode([
            ["renderType": "Popup"],
            ["renderType": "NativeCard"],
            ["renderType": "Web"],
        ]))
    }

    func testMalformedFirstAppFailsWithoutFallback() {
        XCTAssertThrowsError(try decode([
            ["renderType": "App", "fullSlug": "not-a-slug"],
            ["renderType": "App", "fullSlug": "org/valid-later"],
        ])) { XCTAssertEqual($0 as? SkyraError, .invalidDeliveryResponse) }
    }

    func testMalformedListAndHTTPFailureFailClosed() {
        XCTAssertThrowsError(try decode([["fullSlug": "org/popup"]])) {
            XCTAssertEqual($0 as? SkyraError, .invalidDeliveryResponse)
        }
        XCTAssertThrowsError(try decode([], status: 503)) {
            XCTAssertEqual($0 as? SkyraError, .deliveryHTTPStatus(503))
        }
    }

    func testDefaultDecisionCombinesSelectionMetadataAndLocalEligibility() async throws {
        let sdk = try Skyra(configuration: .init(persistence: .ephemeral, organization: "org"))
        var selections = 0
        sdk.loadSurveyList = { _, organization in
            selections += 1
            XCTAssertEqual(organization, "org")
            return "org/first"
        }
        var metadata: [String] = []
        sdk.loadPolicy = { _, slug in
            metadata.append(slug)
            return PresentationPolicy(
                capturePercent: 100,
                minTimeForRetake: nil,
                minTimeForRetrigger: nil,
                initialDelayMilliseconds: 250
            )
        }
        let result = try await sdk.resolvePresentationDecision(slug: nil)
        XCTAssertEqual(result, .present(slug: "org/first", initialDelayMilliseconds: 250))
        XCTAssertEqual(selections, 1)
        XCTAssertEqual(metadata, ["org/first"])
        XCTAssertNil(try sdk.store.storage.update(key: sdk.store.key) { $0 })
    }

    func testDefaultDecisionReturnsFirstCandidateCooldownWithoutFallback() async throws {
        let sdk = try Skyra(configuration: .init(persistence: .ephemeral, organization: "org"))
        var selections = 0
        sdk.loadSurveyList = { _, _ in selections += 1
            return "org/blocked"
        }
        try sdk.store.terminal(
            slug: "org/blocked",
            visitor: StorageTests().visitor,
            session: UUID().uuidString,
            status: .completed
        )
        var metadata: [String] = []
        sdk.loadPolicy = { _, slug in
            metadata.append(slug)
            return PresentationPolicy(
                capturePercent: 100,
                minTimeForRetake: 60,
                minTimeForRetrigger: nil
            )
        }
        let result = try await sdk.resolvePresentationDecision(slug: nil)
        XCTAssertEqual(result, .notShown(.completedCooldown))
        XCTAssertEqual(selections, 1)
        XCTAssertEqual(metadata, ["org/blocked"])
    }

    func testCustomDecisionCannotSwitchExplicitSlugOrSupplyInvalidDelay() async throws {
        for decision in [
            SkyraSurveyDecision.present(slug: "other/switched"),
            .present(slug: "org/requested", initialDelayMilliseconds: .infinity),
        ] {
            let sdk = try Skyra(configuration: .init(
                persistence: .ephemeral,
                surveyDecision: { _ in decision }
            ))
            do {
                _ = try await sdk.resolvePresentationDecision(slug: "org/requested")
                XCTFail("Invalid decision must fail")
            } catch {
                XCTAssertEqual(error as? SkyraError, .invalidConfiguration)
            }
        }
    }

    func testDefaultDecisionIsMemoizedWithinCustomRequest() async throws {
        let sdk = try Skyra(configuration: .init(
            persistence: .ephemeral,
            organization: "org",
            surveyDecision: { context in
                let first = try await context.defaultDecision()
                let second = try await context.defaultDecision()
                XCTAssertEqual(first, second)
                return second
            }
        ))
        var selections = 0
        var randomCalls = 0
        sdk.loadSurveyList = { _, _ in selections += 1
            return "org/selected"
        }
        sdk.loadPolicy = { _, _ in PresentationPolicy(
            capturePercent: 50,
            minTimeForRetake: nil,
            minTimeForRetrigger: nil
        ) }
        sdk.random = { randomCalls += 1
            return 0
        }
        let result = try await sdk.resolvePresentationDecision(slug: nil)
        XCTAssertEqual(result, .present(slug: "org/selected"))
        XCTAssertEqual(selections, 1)
        XCTAssertEqual(randomCalls, 1)
    }

    private func decode(_ surveys: [[String: Any]], status: Int = 200) throws -> String? {
        try SurveyList.decode(
            JSONSerialization.data(withJSONObject: ["surveys": surveys]),
            status: status,
            organization: "org"
        )
    }
}
