// Tests delivery-policy decoding and native history/capture rules without a network request or WebView.
import XCTest
@testable import Skyra

/// XCTest scenarios for the preflight checks shared by explicit and automatic presentation.
final class EligibilityTests: XCTestCase {
    /// Cooldowns must end at the exact millisecond boundary before capture sampling is considered.
    func testTerminalBoundariesAndSampling() throws {
        let fixture = StorageTests()
        var now = fixture.now
        let memory = SkyraMemoryStorage()
        let store = StateStore(storage: memory, origin: fixture.origin, clock: { now })
        for status in [SkyraSavedState.Status.rejected, .completed] {
            try store.terminal(
                slug: "org/survey",
                visitor: fixture.visitor,
                session: UUID().uuidString,
                status: status
            )
            let record = try XCTUnwrap(store.history(slug: "org/survey"))
            let reason: SkyraNotShownReason = status == .rejected ? .rejectedCooldown :
                .completedCooldown
            let policy = PresentationPolicy(
                capturePercent: 50,
                minTimeForRetake: 60,
                minTimeForRetrigger: 60
            )
            XCTAssertEqual(
                policy.evaluate(
                    history: record,
                    now: now + 59_999,
                    random: { XCTFail("Must not sample cooldown")
                        return 0
                    }
                ),
                reason
            )
            XCTAssertNil(policy.evaluate(history: record, now: now + 60_000, random: { 0.499 }))
            XCTAssertEqual(
                policy.evaluate(history: record, now: now + 60_000, random: { 0.5 }),
                .captureNotSelected
            )
            XCTAssertEqual(
                PresentationPolicy(
                    capturePercent: 100,
                    minTimeForRetake: nil,
                    minTimeForRetrigger: nil
                )
                .evaluate(history: record, now: now + 60_000, random: { 0 }),
                reason
            )
            XCTAssertNil(PresentationPolicy(
                capturePercent: 100,
                minTimeForRetake: 0,
                minTimeForRetrigger: 0
            )
            .evaluate(history: record, now: now, random: { XCTFail()
                return 0
            }))
            let bytes = try memory.update(key: fixture.origin.key) { $0 }
            now = record.expiresAt
            XCTAssertNil(try store.history(slug: "org/survey"))
            XCTAssertEqual(try memory.update(key: fixture.origin.key) { $0 }, bytes)
        }
    }

    /// Resumable Capture skips sampling; checking a new visitor's eligibility must not allocate native identity.
    func testCaptureResumesWithoutSamplingAndEmptyReadsAllocateNothing() throws {
        let fixture = StorageTests()
        let memory = SkyraMemoryStorage()
        let store = StateStore(storage: memory, origin: fixture.origin, clock: { fixture.now })
        XCTAssertNil(try store.history(slug: "org/survey"))
        XCTAssertNil(try memory.update(key: fixture.origin.key) { $0 })
        let state = try fixture.state()
        try store.save(state)
        let policy = PresentationPolicy(
            capturePercent: 0,
            minTimeForRetake: nil,
            minTimeForRetrigger: nil
        )
        XCTAssertNil(policy.evaluate(
            history: try store.history(slug: "org/survey"),
            now: fixture.now,
            random: { XCTFail()
                return 1
            }
        ))
        XCTAssertEqual(try store.prepare(slug: "org/survey", resume: true).2, state)
        XCTAssertEqual(policy.evaluate(history: nil, now: fixture.now, random: { XCTFail()
            return 0
        }), .captureNotSelected)
    }

    @MainActor
    func testPolicyProducesCombinedDecisionWithDelayOrSuppressionReason() throws {
        let policy = PresentationPolicy(
            capturePercent: 100,
            minTimeForRetake: nil,
            minTimeForRetrigger: nil,
            initialDelayMilliseconds: 750
        )
        XCTAssertEqual(
            policy.decision(slug: "org/eligible", history: nil, now: 1, random: { XCTFail()
                return 0
            }),
            .present(slug: "org/eligible", initialDelayMilliseconds: 750)
        )

        let fixture = StorageTests()
        let store = StateStore(
            storage: SkyraMemoryStorage(),
            origin: fixture.origin,
            clock: { fixture.now }
        )
        try store.terminal(
            slug: "org/blocked",
            visitor: fixture.visitor,
            session: UUID().uuidString,
            status: .rejected
        )
        let blockedPolicy = PresentationPolicy(
            capturePercent: 100,
            minTimeForRetake: nil,
            minTimeForRetrigger: 60
        )
        XCTAssertEqual(
            blockedPolicy.decision(
                slug: "org/blocked",
                history: try store.history(slug: "org/blocked"),
                now: fixture.now,
                random: { XCTFail("Cooldown must be decided before sampling")
                    return 0
                }
            ),
            .notShown(.rejectedCooldown)
        )
    }

    /// Delivery decoding must distinguish an unavailable survey from malformed policy or transport failures.
    func testDeliveredContractAndUnavailableVersusFailure() throws {
        var survey: [String: Any] = [
            "fullSlug": "org/survey",
            "renderType": "App",
            "cards": [["id": "card"]],
            "capturePercent": 100,
            "minTimeForRetake": NSNull(),
            "minTimeForRetrigger": 0,
        ]
        /// Re-encode this scenario's edited survey fixture to test each delivery field and HTTP status boundary.
        func decode(_ status: Int = 200) throws -> PresentationPolicy? {
            try DeliveryMetadata.decode(
                JSONSerialization.data(withJSONObject: ["survey": survey]),
                status: status,
                slug: "org/survey"
            )
        }
        XCTAssertEqual(
            try decode(),
            PresentationPolicy(capturePercent: 100, minTimeForRetake: nil, minTimeForRetrigger: 0)
        )
        survey["initialDelay"] = 5000
        XCTAssertEqual(try decode()?.initialDelayMilliseconds, 5000)
        survey["initialDelay"] = 0
        XCTAssertEqual(try decode()?.initialDelayMilliseconds, 0)
        for invalid: Any in [true, -1, "5000", NSNull(), Double(Int32.max) + 1] {
            survey["initialDelay"] = invalid
            XCTAssertThrowsError(try decode()) {
                XCTAssertEqual($0 as? SkyraError, .invalidDeliveryResponse)
            }
        }
        survey["initialDelay"] = nil
        XCTAssertNil(try decode(403))
        XCTAssertNil(try decode(404))
        XCTAssertThrowsError(try decode(500)) { XCTAssertEqual(
            $0 as? SkyraError,
            .deliveryHTTPStatus(500)
        ) }
        XCTAssertThrowsError(try decode(302)) { XCTAssertEqual(
            $0 as? SkyraError,
            .deliveryHTTPStatus(302)
        ) }
        XCTAssertThrowsError(try DeliveryMetadata.decode(
            Data("not-json".utf8),
            status: 200,
            slug: "org/survey"
        )) {
            XCTAssertEqual($0 as? SkyraError, .invalidDeliveryResponse)
        }
        survey["capturePercent"] = true
        XCTAssertThrowsError(try decode())
        survey["capturePercent"] = 101
        XCTAssertThrowsError(try decode())
        survey["capturePercent"] = 100
        survey["minTimeForRetake"] = nil
        XCTAssertThrowsError(try decode())
        survey["minTimeForRetake"] = -1
        XCTAssertThrowsError(try decode())
        survey["minTimeForRetake"] = NSNull()
        survey["fullSlug"] = "other/survey"
        XCTAssertThrowsError(try decode())
        survey["fullSlug"] = "org/survey"
        survey["cards"] = []
        XCTAssertNil(try decode())
    }

    /// Delivery requires an explicit valid origin, with HTTP allowed only for loopback development.
    func testMissingOriginAndValidation() async throws {
        do {
            _ = try await DeliveryMetadata.load(origin: nil, slug: "org/survey")
            XCTFail()
        } catch {
            XCTAssertEqual(error as? SkyraError, .missingDeliveryOrigin)
        }
        for origin in [
            "http://example.com",
            "https://example.com/path",
            "https://example.com?query",
        ] {
            XCTAssertThrowsError(
                try SkyraConfiguration(deliveryOrigin: URL(string: origin)!).validate()
            )
        }
        XCTAssertNoThrow(
            try SkyraConfiguration(deliveryOrigin: URL(string: "http://localhost:3212")!).validate()
        )
    }
}
