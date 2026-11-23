import Foundation
import Network
import XCTest
@testable import Skyra

/// Cancels the transport at many points of a request against a listener on the loopback interface.
final class TransportCancelTests: XCTestCase {
    private var server: LoopbackServer!

    override func setUpWithError() throws {
        server = try LoopbackServer()
    }

    override func tearDown() {
        server.stop()
        server = nil
    }

    func testAnUncancelledRequestReturnsTheBodyAndStatus() async throws {
        let (data, status) = try await BoundedTransport.load(
            request(),
            limits: DecisionService.limits
        )

        XCTAssertEqual(status, 200)
        XCTAssertEqual(data, LoopbackServer.body)
    }

    func testARequestCancelledBeforeItStartsThrowsCancellationError() async {
        let request = request()
        let gate = DispatchSemaphore(value: 0)
        let task = Task { () -> (Data, Int) in
            // Hold the task until the test has cancelled it, so the request starts cancelled.
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    gate.wait()
                    continuation.resume()
                }
            }
            return try await BoundedTransport.load(request, limits: DecisionService.limits)
        }
        task.cancel()
        gate.signal()

        switch await task.result {
        case .success:
            XCTFail("A cancelled request returned a response")
        case let .failure(error):
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    /// Cancelling used to invalidate the session before its task existed, and Foundation raised
    /// an exception that ended the process. Every call must end with a response or an error.
    func testCancellingAtAnyPointEndsEveryRequestWithoutCrashing() async {
        let iterations = 2000
        let request = request()
        let outcomes = Outcomes()
        let finished = expectation(description: "every request ended")
        finished.expectedFulfillmentCount = iterations

        for iteration in 0 ..< iterations {
            let task = Task {
                do {
                    let (data, status) = try await BoundedTransport.load(
                        request,
                        limits: DecisionService.limits
                    )
                    outcomes.record(data == LoopbackServer.body && status == 200 ? .response :
                        .wrong)
                } catch is CancellationError {
                    outcomes.record(.cancelled)
                } catch {
                    outcomes.record(.wrong)
                }
                finished.fulfill()
            }

            // Spread the cancellation from before the request starts to after it has finished.
            switch iteration % 4 {
            case 0:
                break
            case 1:
                for _ in 0 ..< iteration % 50 {
                    await Task.yield()
                }

            case 2:
                try? await Task.sleep(nanoseconds: UInt64.random(in: 0 ... 200_000))
            default:
                try? await Task.sleep(nanoseconds: UInt64.random(in: 0 ... 4_000_000))
            }
            task.cancel()
        }

        await fulfillment(of: [finished], timeout: 30)
        let counts = outcomes.counts
        XCTAssertEqual(counts[.wrong, default: 0], 0)
        XCTAssertEqual(counts.values.reduce(0, +), iterations)
        XCTAssertGreaterThan(counts[.cancelled, default: 0], 0)
    }

    private func request() -> URLRequest {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/decide")!)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        return request
    }
}

/// How one transport call ended.
private enum Outcome {
    case response
    case cancelled
    case wrong
}

/// Counts outcomes reported from concurrent tasks.
private final class Outcomes: @unchecked Sendable {
    private let lock = NSLock()
    private var tally: [Outcome: Int] = [:]

    var counts: [Outcome: Int] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return tally
    }

    func record(_ outcome: Outcome) {
        lock.lock()
        tally[outcome, default: 0] += 1
        lock.unlock()
    }
}

/// An HTTP listener on a free loopback port that answers every request with the same small body.
private final class LoopbackServer {
    static let body = Data(#"{"version":1,"inline":[]}"#.utf8)

    let port: UInt16
    private let listener: NWListener
    private let queue = DispatchQueue(label: "TransportCancelTests.server")

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        let listener = try NWListener(using: parameters)
        let queue = queue
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            LoopbackServer.answer(connection, received: Data())
        }

        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled:
                ready.signal()
            default:
                break
            }
        }
        listener.start(queue: queue)
        ready.wait()
        listener.stateUpdateHandler = nil

        guard let port = listener.port?.rawValue else {
            throw URLError(.cannotConnectToHost)
        }

        self.listener = listener
        self.port = port
    }

    func stop() {
        listener.cancel()
    }

    /// Reads until the request's headers and two-byte body have arrived, then answers and closes.
    private static func answer(_ connection: NWConnection, received: Data) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 65536
        ) { chunk, _, ended, error in
            let request = received + (chunk ?? Data())
            if request.range(of: Data("\r\n\r\n{}".utf8)) != nil {
                let head = "HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\n"
                var response = Data((head + "Connection: close\r\n\r\n").utf8)
                response.append(body)
                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            } else if ended || error != nil {
                connection.cancel()
            } else {
                answer(connection, received: request)
            }
        }
    }
}
