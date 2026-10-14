// Tests intrinsic popup geometry and remembered positioning without constructing UIKit controllers.
import XCTest
import CoreGraphics
@testable import Skyra

/// XCTest coverage for temporary size/position constraints around a stable user-selected corner.
final class PopupPlacementTests: XCTestCase {
    /// Host constraints can shrink or move the visible frame without replacing the user's desired corner.
    func testIntrinsicWidthAndTemporaryClampingRetainDesiredCorner() {
        let placement = PopupPlacement(desiredCorner: CGPoint(x: 350, y: 700))
        let area = CGRect(x: 16, y: 60, width: 358, height: 700)
        var layout = PopupLayout(
            contentHeight: 72,
            cornerRadius: 16,
            minimized: true,
            webControls: true,
            contentWidth: 150
        )
        XCTAssertEqual(
            placement.frame(in: area, layout: layout, handleHeight: 0),
            CGRect(x: 200, y: 628, width: 150, height: 72)
        )
        let keyboard = CGRect(x: 16, y: 60, width: 358, height: 250)
        XCTAssertEqual(placement.frame(in: keyboard, layout: layout, handleHeight: 0).maxY, 310)
        XCTAssertEqual(placement.frame(in: area, layout: layout, handleHeight: 0).maxY, 700)
        layout.contentWidth = .greatestFiniteMagnitude
        XCTAssertEqual(placement.frame(in: area, layout: layout, handleHeight: 0).width, 358)
        layout.contentWidth = 1
        XCTAssertEqual(placement.frame(in: area, layout: layout, handleHeight: 0).width, 44)
        XCTAssertEqual(
            placement.frame(
                in: CGRect(x: 0, y: 0, width: 20, height: 10),
                layout: layout,
                handleHeight: 0
            ).size,
            CGSize(width: 20, height: 10)
        )
        layout.contentWidth = nil
        XCTAssertEqual(placement.frame(in: area, layout: layout, handleHeight: 0).width, 358)
        let expanded = PopupLayout(
            contentHeight: 215,
            cornerRadius: 16,
            minimized: false,
            webControls: true,
            contentWidth: 100
        )
        XCTAssertEqual(
            placement.frame(in: area, layout: expanded, handleHeight: 24).size,
            CGSize(width: 358, height: 239)
        )
    }
}
