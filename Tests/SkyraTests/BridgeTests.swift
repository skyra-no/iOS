// Exercises the hosted-message contract without a WebView, using fixed identities and timestamps.
import XCTest
@testable import Skyra

/// XCTest scenarios for message validation and the per-presentation page lifecycle.
final class BridgeTests: XCTestCase {
    let origin = Origin(URL(string: "https://survey.skyra.no")!)!
    let visitor = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
    /// Each scenario starts with a fresh bridge bound to the same deterministic survey and native identity.
    func bridge() -> Bridge {
        Bridge(
            slug: "org/survey",
            visitor: visitor,
            session: "stable-session",
            origin: origin
        )
    }

    /// Build a valid hosted JSON envelope, then override individual fields to test rejection boundaries.
    func message(_ type: String, overrides: [String: Any] = [:]) throws -> Data {
        var value: [String: Any] = [
            "version": 1,
            "type": type,
            "presentationId": "page-1",
            "slug": "org/survey",
            "visitorId": visitor,
            "sessionId": "stable-session",
            "surveyId": "82F58CA1-35C9-498F-9454-A48A3E962718",
        ]
        value.merge(overrides) { _, new in new }
        return try JSONSerialization.data(withJSONObject: value)
    }

    /// Test shorthand for delivering a message from the expected frame/origin at the fixture's fixed time.
    func receive(
        _ bridge: Bridge,
        _ type: String,
        _ overrides: [String: Any] = [:]
    ) throws -> Bridge.Event {
        bridge.receive(
            try message(type, overrides: overrides),
            mainFrame: true,
            source: origin,
            now: 1_789_391_234_567
        )
    }

    /// Assert ignored events while reporting the calling scenario's source location on failure.
    func ignored(_ event: Bridge.Event, file: StaticString = #filePath, line: UInt = #line) {
        guard case .ignored = event else {
            return XCTFail(
                "Expected ignored message",
                file: file,
                line: line
            )
        }
    }

    /// Prevents foreign frames, origins, protocol versions, and identities from controlling a presentation.
    func testFrameOriginAndIdentityGate() throws {
        let b = bridge()
        let data = try message("ready")
        ignored(b.receive(data, mainFrame: false, source: origin, now: 0))
        ignored(b.receive(
            data,
            mainFrame: true,
            source: Origin(URL(string: "https://evil.test")!),
            now: 0
        ))
        for override: [String: Any] in [
            ["version": 2],
            ["slug": "org/other"],
            ["visitorId": "bad"],
            ["sessionId": "other"],
            ["surveyId": "bad"],
        ] {
            ignored(try receive(b, "ready", override))
        }
        XCTAssertFalse(b.ready)
        _ = try receive(b, "ready")
        XCTAssertTrue(b.ready)
        ignored(try receive(b, "completed", ["presentationId": "old-page"]))
        ignored(try receive(b, "completed", ["surveyId": UUID().uuidString]))
    }

    /// Visual readiness is a one-time display signal, not an identity handshake or answer acknowledgment.
    func testVisualReadinessCannotEstablishIdentityOrAcceptAnswers() throws {
        let b = bridge()
        ignored(try receive(b, "visualReady"))
        XCTAssertNil(b.presentation)
        _ = try receive(b, "ready")
        for override: [String: Any] in [
            ["version": 2],
            ["slug": "org/other"],
            ["visitorId": "other"],
            ["sessionId": "other"],
            ["surveyId": UUID().uuidString],
            ["presentationId": "old"],
        ] {
            ignored(try receive(b, "visualReady", override))
        }
        let data = try message("visualReady")
        ignored(b.receive(data, mainFrame: false, source: origin, now: 0))
        ignored(b.receive(
            data,
            mainFrame: true,
            source: Origin(URL(string: "https://survey.skyra.no:444")!),
            now: 0
        ))
        guard case .visualReady = try receive(b, "visualReady") else {
            return XCTFail()
        }

        XCTAssertFalse(b.accepted)
        XCTAssertFalse(b.finished)
        ignored(try receive(b, "visualReady"))
        b.stopReceivingMessages()
        ignored(try receive(b, "visualReady"))
    }

    /// Layout must belong to the initialized current page and stop being actionable after teardown starts.
    func testLayoutRequiresReadyAndCompleteCurrentIdentity() throws {
        let b = bridge()
        let layout: [String: Any] = [
            "contentHeight": 72,
            "cornerRadius": 16,
            "minimized": true,
            "webControls": true,
        ]
        ignored(try receive(b, "layout", ["layout": layout]))
        XCTAssertNil(b.presentation)
        _ = try receive(b, "ready")
        for override: [String: Any] in [
            ["version": 2],
            ["slug": "org/other"],
            ["visitorId": "other"],
            ["sessionId": "other"],
            ["surveyId": UUID().uuidString],
            ["presentationId": "old"],
        ] {
            ignored(try receive(
                b,
                "layout",
                override.merging(["layout": layout]) { _, new in new }
            ))
        }
        let data = try message("layout", overrides: ["layout": layout])
        ignored(b.receive(data, mainFrame: false, source: origin, now: 0))
        ignored(b.receive(
            data,
            mainFrame: true,
            source: Origin(URL(string: "https://survey.skyra.no:444")!),
            now: 0
        ))
        guard case .layout(let accepted) = try receive(b, "layout", ["layout": layout])
        else {
            return XCTFail()
        }

        XCTAssertTrue(accepted.minimized)
        XCTAssertEqual(accepted.preferredHeight, 72)
        XCTAssertFalse(b.finished)
        b.stopReceivingMessages()
        XCTAssertTrue(b.finished)
        ignored(try receive(b, "layout", ["layout": layout]))
    }

    /// Invalid measurements must not resize or terminate the survey; omitted widths retain compatibility.
    func testMalformedLayoutIsIgnoredWithoutEndingSurvey() throws {
        let b = bridge()
        _ = try receive(b, "ready")
        let layout: [String: Any] = [
            "contentHeight": 200,
            "cornerRadius": 20,
            "minimized": false,
            "webControls": false,
        ]
        for override: [String: Any] in [
            ["contentHeight": 0],
            ["contentHeight": -1],
            ["contentHeight": 100_001],
            ["contentHeight": "200"],
            ["contentHeight": true],
            ["cornerRadius": 0],
            ["cornerRadius": 1_001],
            ["minimized": 1],
            ["webControls": "true"],
            ["minimized": NSNull()],
            ["contentWidth": 0],
            ["contentWidth": -1],
            ["contentWidth": "150"],
            ["contentWidth": true],
            ["contentWidth": NSNull()],
        ] {
            ignored(try receive(
                b,
                "layout",
                ["layout": layout.merging(override) { _, new in new }]
            ))
        }
        ignored(try receive(b, "layout"))
        XCTAssertFalse(PopupLayout(
            contentHeight: .infinity,
            cornerRadius: 20,
            minimized: false,
            webControls: true
        ).isValid)
        XCTAssertFalse(PopupLayout(
            contentHeight: 20,
            cornerRadius: .nan,
            minimized: false,
            webControls: true
        ).isValid)
        for width in [Double.infinity, .nan, 0, -1] {
            XCTAssertFalse(PopupLayout(
                contentHeight: 72,
                cornerRadius: 16,
                minimized: true,
                webControls: true,
                contentWidth: width
            ).isValid)
        }
        for width in [44.0, 150, Double.greatestFiniteMagnitude] {
            guard
                case .layout(let accepted) = try receive(
                    b,
                    "layout",
                    ["layout": layout.merging(["contentWidth": width]) { _, new in new }]
                )
            else {
                return XCTFail()
            }

            XCTAssertEqual(accepted.contentWidth, width)
        }
        XCTAssertFalse(b.finished)
    }

    /// Initialization constrains text scale while explicitly disabling browser-state fallback with null.
    func testOptionalTextScaleIsBoundedAndPreservesNullState() throws {
        var value = Initialization(
            visitorId: visitor,
            sessionId: "s",
            language: nil,
            device: "mobile",
            traits: [:],
            savedState: nil
        )
        XCTAssertFalse(try value.json().contains("textScale"))
        for scale in [1.0, 3.0] {
            value.textScale = scale
            let object = try XCTUnwrap(JSONSerialization
                .jsonObject(with: Data(value.json().utf8)) as? [String: Any])
            XCTAssertEqual(object["textScale"] as? Double, scale)
            XCTAssertTrue(object["savedState"] is NSNull)
        }
        for scale in [0.9, 3.1, Double.infinity, Double.nan] {
            value.textScale = scale
            XCTAssertThrowsError(try value.json())
        }
    }

    /// Confirmed answers stay accepted while native teardown stops later state and rejection messages.
    func testAcceptedCompletionSurvivesStoppingMessages() throws {
        let b = bridge()
        ignored(try receive(b, "completed"))
        _ = try receive(b, "ready")
        let state = try StorageTests().state(status: "Completed")
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state))
        guard case .state = try receive(b, "state", ["state": object])
        else {
            return XCTFail("Expected state")
        }

        XCTAssertFalse(b.finished)
        XCTAssertTrue(b.accepted)
        let capture = try JSONSerialization
            .jsonObject(with: JSONEncoder().encode(StorageTests().state()))
        ignored(try receive(b, "state", ["state": capture]))
        guard case .terminal(.completed) = try receive(b, "completed")
        else {
            return XCTFail("Expected acknowledgment")
        }

        b.stopReceivingMessages()
        b.stopReceivingMessages()
        XCTAssertTrue(b.finished)
        XCTAssertTrue(b.accepted)
        ignored(try receive(b, "state", ["state": object]))
        ignored(try receive(b, "rejected"))
    }

    /// Initialization may fail before readiness; recoverable page errors must leave the presentation alive.
    func testInitialAndRecoverableErrors() throws {
        let b = bridge()
        let data = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "slug": "org/survey",
            "type": "error",
            "presentationId": "initialization",
            "code": "survey_unavailable",
        ])
        guard
            case .terminal(.unavailable) = b
                .receive(data, mainFrame: true, source: origin, now: 0)
        else {
            return XCTFail()
        }

        _ = try receive(b, "ready")
        guard
            case .recoverable("state_expired") = try receive(
                b,
                "error",
                ["code": "state_expired", "recoverable": true]
            )
        else {
            return XCTFail()
        }

        XCTAssertFalse(b.finished)
        guard
            case .terminal(.failure("future_code")) = try receive(
                b,
                "error",
                ["code": "future_code"]
            )
        else {
            return XCTFail()
        }
    }

    /// Early errors may omit identity but cannot smuggle mismatched IDs into a later ready handshake.
    func testInitializationErrorsValidateOptionalIdentityWithoutBinding() throws {
        let bridge = bridge()
        let initialization: [String: Any] = [
            "presentationId": "initialization",
            "visitorId": NSNull(),
            "sessionId": NSNull(),
            "surveyId": NSNull(),
            "code": "load_failed",
        ]

        for invalidIdentity in [
            ["visitorId": "another-visitor"],
            ["sessionId": "another-session"],
            ["surveyId": "not-a-uuid"],
        ] {
            let overrides = initialization.merging(invalidIdentity) { _, new in new }
            ignored(try receive(bridge, "error", overrides))
        }

        guard
            case .terminal(.failure("load_failed")) = try receive(
                bridge,
                "error",
                initialization
            )
        else {
            return XCTFail("Expected initialization failure without requiring identity")
        }

        XCTAssertNil(bridge.presentation)
        XCTAssertNil(bridge.survey)
        XCTAssertFalse(bridge.ready)

        _ = try receive(bridge, "ready")
        XCTAssertTrue(bridge.ready)
        XCTAssertEqual(bridge.presentation, "page-1")
    }

    /// Out-of-order progress must not replace a newer snapshot; equal timestamps remain acceptable.
    func testStaleStateCannotOverwriteLatestProgress() throws {
        let bridge = bridge()
        let fixtures = StorageTests()
        let state = try fixtures.state()
        let current = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state))
        let olderState = try fixtures.state(updated: fixtures.now - 1)
        let older = try JSONSerialization.jsonObject(with: JSONEncoder().encode(olderState))
        _ = try receive(bridge, "ready")

        guard case .state = try receive(bridge, "state", ["state": current]) else {
            return XCTFail("Expected current progress")
        }

        ignored(try receive(bridge, "state", ["state": older]))

        guard case .state = try receive(bridge, "state", ["state": current]) else {
            return XCTFail("Equal timestamps should still be accepted")
        }

        XCTAssertFalse(bridge.accepted)
        XCTAssertFalse(bridge.finished)
    }

    /// Initialization preserves arbitrary trait text as JSON data and rejects an oversized payload.
    func testInitializationExplicitNullAndSafeStringRoundTrip() throws {
        let traits = ["name": "</script>\"\\\n😊"]
        let json = try Initialization(
            visitorId: visitor,
            sessionId: "session",
            language: "en",
            device: "mobile",
            traits: traits,
            savedState: nil
        ).json()
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )
        XCTAssertTrue(decoded["savedState"] is NSNull)
        XCTAssertEqual(decoded["traits"] as? [String: String], traits)
        XCTAssertThrowsError(try Initialization(
            visitorId: visitor,
            sessionId: "s",
            language: nil,
            device: "mobile",
            traits: ["huge": String(repeating: "a", count: 65_536)],
            savedState: nil
        ).json())
    }

    /// Identifier boundaries and configuration length/origin checks match the hosted contract.
    func testStrictIdentifiersAndUTF16ConfigurationLimits() throws {
        XCTAssertFalse(Identifiers.isValidSessionID("session\n"))
        XCTAssertFalse(Identifiers.isValidSurveySlug("org/survey\n"))
        XCTAssertFalse(Identifiers.isValidVisitorID(visitor + "\n"))
        XCTAssertThrowsError(try SkyraConfiguration(language: String(repeating: "😊", count: 18))
            .validate())
        XCTAssertThrowsError(try SkyraConfiguration(traits: ["key": String(
            repeating: "😊",
            count: 257
        )]).validate())
        XCTAssertThrowsError(
            try SkyraConfiguration(hostedOrigin: URL(string: "http://untrusted.example")!)
                .validate()
        )
        XCTAssertNoThrow(try SkyraConfiguration(hostedOrigin: URL(string: "http://localhost:5173")!)
            .validate())
    }

    /// A recoverable flag cannot soften a fatal code, even after an earlier recoverable initialization error.
    func testFatalCodeCannotBeDowngradedAndInitializationFailureAfterRecovery() throws {
        let b = bridge()
        _ = try receive(b, "error", ["code": "state_mismatch", "recoverable": true])
        let initial = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "slug": "org/survey",
            "type": "error",
            "presentationId": "initialization",
            "code": "load_failed",
            "recoverable": true,
        ])
        guard
            case .terminal(.failure("load_failed")) = b.receive(
                initial,
                mainFrame: true,
                source: origin,
                now: 0
            )
        else {
            return XCTFail()
        }
    }
}
