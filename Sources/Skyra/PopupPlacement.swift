// Calculates popup geometry separately from UIKit callbacks so placement can be tested directly.
import Foundation
import CoreGraphics

/// The desired bottom-right corner survives temporary keyboard/host clamping.
/// Nil follows the available bottom-trailing corner until the first drag.
struct PopupPlacement {
    var desiredCorner: CGPoint?

    /// SurveyController supplies safe, keyboard-adjusted bounds and the latest hosted measurements.
    /// Return a visible frame while preserving the user's desired corner for later bounds changes.
    func frame(in available: CGRect, layout: PopupLayout?, handleHeight: CGFloat) -> CGRect {
        let widthLimit = max(0, available.width)
        let width: CGFloat
        if let layout, layout.minimized, let intrinsic = layout.contentWidth {
            // Clamp as Double before conversion/arithmetic, including huge valid reports.
            width = min(widthLimit, CGFloat(min(Double(widthLimit), max(44, intrinsic))))
        } else {
            width = min(400, widthLimit)
        }
        let height = min(
            max(0, available.height),
            CGFloat(layout?.preferredHeight ?? 420) + handleHeight
        )
        let corner = desiredCorner ?? CGPoint(x: available.maxX, y: available.maxY)
        return CGRect(
            x: min(max(corner.x - width, available.minX), available.maxX - width),
            y: min(max(corner.y - height, available.minY), available.maxY - height),
            width: width,
            height: height
        )
    }
}
