// Represents the hosted page's size report before SurveyController applies it to native popup views.
import Foundation

/// Intrinsic CSS-pixel measurements at the current viewport width, excluding native chrome.
struct PopupLayout: Decodable, Equatable {
    private static let maximumContentHeightCSSPixels = 100_000.0
    private static let maximumCornerRadiusCSSPixels = 1_000.0
    private static let nativeHeaderHeight = 48.0

    let contentHeight: Double
    let cornerRadius: Double
    let minimized: Bool
    let webControls: Bool
    var contentWidth: Double? = nil

    /// Native tests construct layout reports directly to exercise sizing without running JavaScript.
    init(
        contentHeight: Double,
        cornerRadius: Double,
        minimized: Bool,
        webControls: Bool,
        contentWidth: Double? = nil
    ) {
        self.contentHeight = contentHeight
        self.cornerRadius = cornerRadius
        self.minimized = minimized
        self.webControls = webControls
        self.contentWidth = contentWidth
    }

    /// Field names shared with the hosted page's layout message.
    private enum CodingKeys: String, CodingKey {
        case contentHeight
        case cornerRadius
        case minimized
        case webControls
        case contentWidth
    }

    /// Bridge message decoding calls this to distinguish an omitted optional width from invalid null.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        contentHeight = try container.decode(Double.self, forKey: .contentHeight)
        cornerRadius = try container.decode(Double.self, forKey: .cornerRadius)
        minimized = try container.decode(Bool.self, forKey: .minimized)
        webControls = try container.decode(Bool.self, forKey: .webControls)
        // Width may be absent, but explicit null is not a valid measurement.
        if container.contains(.contentWidth) {
            contentWidth = try container.decode(Double.self, forKey: .contentWidth)
        } else {
            contentWidth = nil
        }
    }

    /// Bridge and SurveyController require finite, positive measurements before using this report.
    var isValid: Bool {
        contentHeight.isFinite && cornerRadius.isFinite &&
            contentHeight > 0 && contentHeight <= Self.maximumContentHeightCSSPixels &&
            cornerRadius > 0 && cornerRadius <= Self.maximumCornerRadiusCSSPixels &&
            (contentWidth.map { $0.isFinite && $0 > 0 } ?? true)
    }

    /// PopupPlacement uses this to include the native close header when the page has no own controls.
    var preferredHeight: Double {
        contentHeight + (webControls ? 0 : Self.nativeHeaderHeight)
    }
}
