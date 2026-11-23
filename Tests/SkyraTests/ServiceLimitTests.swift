import XCTest
@testable import Skyra

/// The SDK keeps to the decision service's own limits, so it never sends a request the service refuses.
final class ServiceLimitTests: XCTestCase {
    private let now = Fixture.now

    func testASessionThatIsNotAULIDIsNotStored() throws {
        let sdk = try Fixture.sdk()
        let merged = try sdk.sync(SkyraState(visitorId: Fixture.olderVisitor, surveys: [
            "org/ulid": .init(state: .capture, lastSync: now, sessionId: Fixture.session),
            "org/other": .init(state: .capture, lastSync: now, sessionId: "my-session_1"),
        ]))

        XCTAssertEqual(Array(merged.surveys.keys), ["org/ulid"])
    }

    func testATraitNameThatIsNotASlugIsRefused() async throws {
        let service = StubDecisionService()
        let sdk = try Fixture.sdk(service: service)

        for name in ["my trait", "æ", "_plan", "__proto__", String(repeating: "a", count: 101)] {
            do {
                _ = try await sdk.getSurveys(traits: [name: "x"])
                XCTFail("Expected invalid traits for \(name)")
            } catch {
                XCTAssertEqual(error as? SkyraError, .invalidTraits, name)
            }
        }
        XCTAssertEqual(service.requests.count, 0)
    }

    func testConfiguredAndCallTraitsTogetherStayWithinTheLimit() async throws {
        let service = StubDecisionService()
        let configured = Dictionary(uniqueKeysWithValues: (0 ..< 30).map { ("plan-\($0)", "x") })
        let moment = Dictionary(uniqueKeysWithValues: (0 ..< 30).map { ("screen-\($0)", "x") })
        let sdk = try Fixture.sdk(service: service, configuration: .init(
            organization: "org",
            traits: configured,
            persistence: .ephemeral
        ))

        do {
            _ = try await sdk.getSurveys(traits: moment)
            XCTFail("Expected invalid traits")
        } catch {
            XCTAssertEqual(error as? SkyraError, .invalidTraits)
        }
        XCTAssertEqual(service.requests.count, 0)
    }

    func testProgressIsKeptOnlyWhileTheVisitorIsAnswering() throws {
        let sdk = try Fixture.sdk()
        let progress = Data(#"{"currentCard":1}"#.utf8)
        let merged = try sdk.sync(SkyraState(visitorId: Fixture.olderVisitor, surveys: [
            "org/open": .init(state: .capture, lastSync: now, progress: progress),
            "org/done": .init(state: .completed, lastSync: now, progress: progress),
            "org/closed": .init(state: .rejected, lastSync: now, progress: progress),
        ]))

        XCTAssertNotNil(merged.surveys["org/open"]?.progress)
        XCTAssertNil(merged.surveys["org/done"]?.progress)
        XCTAssertNil(merged.surveys["org/closed"]?.progress)
    }

    func testAStorageThatSkipsTheTransformIsAStorageFailure() throws {
        final class IdleStorage: SkyraStorage {
            func update(key: String, _ transform: (Data?) throws -> Data?) throws -> Data? {
                nil
            }
        }
        let sdk = try Fixture.sdk(storage: IdleStorage())

        XCTAssertThrowsError(try sdk.state()) {
            XCTAssertEqual($0 as? SkyraError, .storageFailure)
        }
    }

    func testReadingTheStateTwiceStoresTheSameBytes() throws {
        final class RecordingStorage: SkyraStorage {
            let inner = SkyraMemoryStorage()
            var written: [Data?] = []

            func update(key: String, _ transform: (Data?) throws -> Data?) throws -> Data? {
                let data = try inner.update(key: key, transform)
                written.append(data)
                return data
            }
        }
        let storage = RecordingStorage()
        let sdk = try Fixture.sdk(storage: storage)
        var surveys: [String: SkyraState.Survey] = [:]
        for index in 0 ..< 30 {
            surveys["org/survey-\(index)"] = .init(state: .selected, lastSync: now)
        }
        try sdk.sync(SkyraState(visitorId: Fixture.olderVisitor, surveys: surveys))

        _ = try sdk.state()
        _ = try sdk.state()

        XCTAssertEqual(storage.written.suffix(2).first, storage.written.last)
    }

    func testATimeWithALongDecimalTailIsReadAsTheSameTime() throws {
        let json = Data(#"""
        {"visitorId":"\#(Fixture.olderVisitor)","surveys":{
          "org/feedback":{"state":"Completed","lastSync":1794832273590.0000001}}}
        """#.utf8)

        XCTAssertEqual(
            try SkyraState(json: json).surveys["org/feedback"]?.lastSync,
            1_794_832_273_590
        )
    }

    func testTheVersionMatchesTheLatestChangelogEntry() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let changelog = try String(
            contentsOf: root.appendingPathComponent("CHANGELOG.md"),
            encoding: .utf8
        )
        let latest = changelog.components(separatedBy: "\n").first { $0.hasPrefix("## ") }

        XCTAssertEqual(latest, "## \(Skyra.version)")
    }

    func testEveryErrorDescribesItself() {
        XCTAssertEqual(
            SkyraError.decisionHTTPStatus(404).localizedDescription,
            "The Skyra decision service answered with HTTP status 404."
        )
    }
}
