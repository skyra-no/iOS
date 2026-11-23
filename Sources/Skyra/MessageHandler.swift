// Receives what the Skyra widget in a web view reports, stores it, and tells the app what changed.
#if canImport(WebKit)
import WebKit

/// Told when the survey in your web view changes state, after the SDK has stored it.
/// Use it to close the web view when a survey is finished, or for your own analytics.
@MainActor
public protocol SkyraSurveyListener: AnyObject {
    /// `slug` is the survey, such as `acme/feedback`. Called on the main thread.
    func surveyDidChange(_ slug: String, to state: SkyraState.Status)
}

public extension Skyra {
    /// Receives everything the Skyra widget reports from your web view and stores it with `sync(_:)`.
    /// Register it under `Skyra.messageHandlerName`:
    ///
    ///     configuration.userContentController.add(skyra.messageHandler, name: Skyra.messageHandlerName)
    ///
    /// Messages from embedded frames are ignored, so only your page can write state.
    @MainActor
    var messageHandler: WKScriptMessageHandler {
        SkyraMessageHandler(skyra: self, listener: nil)
    }

    /// The same handler, which also tells `listener` when a survey changes state. The listener is
    /// held weakly, so a view controller that owns the web view can be its own listener.
    @MainActor
    func messageHandler(listener: SkyraSurveyListener) -> WKScriptMessageHandler {
        SkyraMessageHandler(skyra: self, listener: listener)
    }
}

@MainActor
final class SkyraMessageHandler: NSObject, WKScriptMessageHandler {
    private let skyra: Skyra
    private weak var listener: SkyraSurveyListener?

    init(skyra: Skyra, listener: SkyraSurveyListener?) {
        self.skyra = skyra
        self.listener = listener
    }

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard
            message.frameInfo.isMainFrame,
            let reported = try? SkyraState(widget: message.body)
        else {
            return
        }

        let before = try? skyra.state()
        guard let stored = try? skyra.sync(reported), let listener else {
            return
        }

        // Only the surveys this message was about, and only when their stored state changed.
        for slug in reported.surveys.keys.sorted() {
            if let state = stored.surveys[slug]?.state, state != before?.surveys[slug]?.state {
                listener.surveyDidChange(slug, to: state)
            }
        }
    }
}
#endif
