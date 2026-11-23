import Foundation
import XCTest
@testable import Skyra

/// A clock the test moves by hand. Skyra reads it from any thread, so access is locked.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64

    init(_ value: Int64) {
        self.value = value
    }

    var now: Int64 {
        lock.lock()
        defer {
            lock.unlock()
        }
        return value
    }

    func advance(_ milliseconds: Int64) {
        lock.lock()
        value += milliseconds
        lock.unlock()
    }
}

/// Stands in for the decision service: records each request and answers with the surveys it was given.
final class StubDecisionService: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(URL, DecisionRequest)] = []
    private var answer: [SkyraSurvey]

    init(answer: [SkyraSurvey] = []) {
        self.answer = answer
    }

    var requests: [DecisionRequest] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return recorded.map(\.1)
    }

    var origins: [URL] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return recorded.map(\.0)
    }

    func decide(origin: URL, request: DecisionRequest) -> [SkyraSurvey] {
        lock.lock()
        defer {
            lock.unlock()
        }
        recorded.append((origin, request))
        return answer
    }
}

/// A backend that fails every update, for storage-failure paths.
final class FailingStorage: SkyraStorage {
    struct Failure: Error {}

    func update(key: String, _ transform: (Data?) throws -> Data?) throws -> Data? {
        throw Failure()
    }
}

enum Fixture {
    static let now: Int64 = 1_789_391_234_567
    static let year: Int64 = 31_536_000_000
    /// Created well before `now`, as a widget's visitor would be.
    static let olderVisitor = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
    static let session = "01JD8ZR1M4XQ2B7C9D0E1F2G3H"
    static let feedback = SkyraSurvey(slug: "org/feedback", language: "en")

    /// An SDK for organisation `org` on the test's clock, storage, and decision service.
    static func sdk(
        clock: TestClock = TestClock(now),
        storage: SkyraStorage = SkyraMemoryStorage(),
        service: StubDecisionService = StubDecisionService(),
        configuration: SkyraConfiguration = .init(
            organization: "org",
            persistence: .ephemeral
        )
    ) throws -> Skyra {
        try Skyra(
            configuration: configuration,
            storage: storage,
            clock: { clock.now },
            decide: { service.decide(origin: $0, request: $1) }
        )
    }
}

extension Skyra {
    /// Stores one survey entry at the test clock's time, the way an app records what a visitor did.
    func record(
        _ survey: SkyraSurvey,
        _ state: SkyraState.Status,
        sessionId: String? = nil
    ) throws {
        try sync(SkyraState(visitorId: self.state().visitorId, surveys: [
            survey.slug: .init(state: state, lastSync: store.clock(), sessionId: sessionId),
        ]))
    }
}
