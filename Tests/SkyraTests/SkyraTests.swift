// Checks the public module boundary using the same non-testable import available to customer apps.
import Skyra
import Foundation
import XCTest

/// XCTest smoke test for the package's exported SDK namespace.
final class SkyraTests: XCTestCase {
    /// A regular package import must expose the Skyra type without relying on test-only access.
    func testPublicNamespaceIsAvailableFromTheSkyraModule() {
        XCTAssertEqual(String(reflecting: Skyra.self), "Skyra.Skyra")
    }

    /// Standard initialization reads centralized endpoints; explicit overrides remain instance-local.
    func testServiceDefaultsAndOverrides() {
        let standard = SkyraConfiguration()
        XCTAssertEqual(standard.hostedOrigin, SkyraDefaults.hostedOrigin)
        XCTAssertEqual(standard.deliveryOrigin, SkyraDefaults.deliveryOrigin)
        XCTAssertEqual(standard.hostedOrigin.absoluteString, "https://survey.skyra.no")
        XCTAssertEqual(standard.deliveryOrigin?.absoluteString, "https://ingest.skyra.no")

        let hosted = URL(string: "https://hosted.example.com")!
        let delivery = URL(string: "https://delivery.example.com")!
        let custom = SkyraConfiguration(hostedOrigin: hosted, deliveryOrigin: delivery)
        XCTAssertEqual(custom.hostedOrigin, hosted)
        XCTAssertEqual(custom.deliveryOrigin, delivery)
        XCTAssertEqual(SkyraConfiguration().hostedOrigin, standard.hostedOrigin)
        XCTAssertEqual(SkyraConfiguration().deliveryOrigin, standard.deliveryOrigin)
    }
}
