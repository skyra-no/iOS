import XCTest

/// Shared executor-turn helper for asynchronous presentation fixtures.
@MainActor
final class DecisionTests: XCTestCase {
    func flush() async {
        let done = expectation(description: "main actor turn")
        DispatchQueue.main.async { done.fulfill() }
        await fulfillment(of: [done], timeout: 2)
    }
}
