// Checks the public module boundary using the same non-testable import available to customer apps.
import Foundation
import Skyra
import XCTest

/// Everything here must compile and run with only what the package exports.
final class SkyraTests: XCTestCase {
    func testAnAppCanUseTheWholeToolkitThroughThePublicAPI() throws {
        let skyra = try Skyra(
            configuration: .init(
                organization: "acme",
                language: "nb",
                traits: ["plan": "premium"],
                persistence: .ephemeral
            ),
            storage: SkyraMemoryStorage()
        )
        let survey = SkyraSurvey(slug: "acme/feedback", language: "nb")

        let visitor = try skyra.state().visitorId
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try skyra.sync(SkyraState(visitorId: visitor, surveys: [
            survey.slug: .init(
                state: .capture,
                lastSync: now - 1000,
                sessionId: "01JD8ZR1M4XQ2B7C9D0E1F2G3H"
            ),
        ]))
        try skyra.sync(SkyraState(visitorId: visitor, surveys: [
            survey.slug: .init(
                state: .completed,
                lastSync: now,
                sessionId: "01JD8ZR1M4XQ2B7C9D0E1F2G3H"
            ),
        ]))

        let state = try skyra.state()
        XCTAssertEqual(state.surveys["acme/feedback"]?.state, .completed)
        XCTAssertEqual(state.surveys["acme/feedback"]?.sessionId, "01JD8ZR1M4XQ2B7C9D0E1F2G3H")

        let widget = try SkyraState(json: state.json())
        XCTAssertEqual(try skyra.sync(widget), state)
    }

    func testServiceDefaultAndOverride() {
        XCTAssertEqual(SkyraDefaults.decisionOrigin.absoluteString, "https://ingest.skyra.no")
        XCTAssertEqual(
            SkyraConfiguration(organization: "acme").decisionOrigin,
            SkyraDefaults.decisionOrigin
        )

        let local = URL(string: "http://localhost:3212")!
        XCTAssertEqual(
            SkyraConfiguration(
                organization: "acme",
                decisionOrigin: local
            ).decisionOrigin,
            local
        )
    }

    func testUnusableConfigurationIsRefused() {
        let unusable: [SkyraConfiguration] = [
            .init(organization: ""),
            .init(organization: "acme/feedback"),
            .init(organization: String(repeating: "a", count: 101)),
            .init(organization: "acme", language: "x"),
            .init(organization: "acme", language: String(repeating: "a", count: 36)),
            .init(organization: "acme", language: "nb_NO"),
            .init(organization: "acme", language: "<b>"),
            .init(organization: "acme", language: "nø"),
            .init(organization: "acme", language: "nb\n"),
            .init(organization: "acme", traits: ["__proto__": "x"]),
            .init(
                organization: "acme",
                traits: Dictionary(uniqueKeysWithValues: (0 ..< 50).map { ("trait-\($0)", "x") })
            ),
            .init(
                organization: "acme",
                decisionOrigin: URL(string: "https://:443")!
            ),
            .init(
                organization: "acme",
                traits: ["plan": String(repeating: "x", count: 257)]
            ),
            .init(
                organization: "acme",
                decisionOrigin: URL(string: "http://example.com")!
            ),
            .init(
                organization: "acme",
                decisionOrigin: URL(string: "https://example.com/path")!
            ),
            .init(
                organization: "acme",
                decisionOrigin: URL(string: "https://user@example.com")!
            ),
            .init(
                organization: "acme",
                decisionOrigin: URL(string: "ftp://example.com")!
            ),
        ]
        for configuration in unusable {
            XCTAssertThrowsError(try Skyra(configuration: configuration)) {
                XCTAssertEqual($0 as? SkyraError, .invalidConfiguration)
            }
        }
        XCTAssertNoThrow(try Skyra(configuration: .init(
            organization: "acme",
            persistence: .ephemeral,
            decisionOrigin: URL(string: "http://localhost:3212")!
        )))
    }

    func testConfigurationAtTheLimitsIsAccepted() {
        let usable: [SkyraConfiguration] = [
            .init(organization: String(repeating: "a", count: 100), persistence: .ephemeral),
            .init(organization: "acme", language: "nb", persistence: .ephemeral),
            .init(organization: "acme", language: "en-GB", persistence: .ephemeral),
            .init(
                organization: "acme",
                language: "zh-Hant-TW",
                persistence: .ephemeral
            ),
            .init(
                organization: "acme",
                traits: Dictionary(uniqueKeysWithValues: (0 ..< 49).map { ("trait-\($0)", "x") }),
                persistence: .ephemeral
            ),
        ]
        for configuration in usable {
            XCTAssertNoThrow(try Skyra(configuration: configuration))
        }
    }
}
