// Turns hosted-page messages into native events for SurveyController.
// Persistent survey data belongs to StateStore; this file keeps only the current message lifecycle.
import Foundation

/// Interprets messages from the hosted survey for one presentation.
/// `receive` validates the sender, updates the page's lifecycle, and returns an event.
/// SurveyController acts on that event: showing the popup, saving progress, or closing it.
/// A class lets the controller retain one object whose state is updated by successive messages.
final class Bridge {
    private static let maximumMessageBytes = 256 * 1024
    private static let maximumPresentationIDCharacters = 128
    private static let fatalErrorCodes = [
        "invalid_initialization",
        "initialization_timeout",
        "survey_unavailable",
        "load_failed",
        "capture_failed",
    ]

    // The native caller supplies these before the page loads.
    let slug: String
    let visitor: String
    let session: String
    let origin: Origin
    // The page supplies these in its initial ready/error message. Later messages must match.
    private(set) var presentation: String?
    private(set) var survey: String?

    /// The page has completed its initialization handshake.
    private(set) var ready = false
    /// Native teardown has started; ignore any messages still arriving from the page.
    private(set) var finished = false
    /// The page has confirmed answer acceptance. Later dismissal cannot undo completion.
    private(set) var accepted = false
    /// The page's initial content is ready to show, independently of the handshake.
    private(set) var visualReady = false
    private var latestStateTimestamp: Int64 = -1

    /// An instruction or notification returned to SurveyController after validating a page message.
    enum Event {
        case ready
        case visualReady
        case layout(PopupLayout)
        case state(SkyraSavedState)
        case terminal(SkyraResult)
        case recoverable(String)
        case ignored
    }

    /// SurveyController supplies the expected native identity before loading the hosted page.
    init(slug: String, visitor: String, session: String, origin: Origin) {
        self.slug = slug
        self.visitor = visitor
        self.session = session
        self.origin = origin
    }

    /// Called when SurveyController begins teardown, before removing the WebView.
    func stopReceivingMessages() {
        finished = true
    }

    /// Called by SurveyController's WebKit message callback. Validate JSON and interpret its event here.
    /// Invalid or late messages return ignored; valid progress is returned for the controller to save.
    func receive(_ data: Data, mainFrame: Bool, source: Origin?, now: Int64) -> Event {
        // Reject late, malformed, or foreign messages before interpreting their event.
        guard
            !finished,
            mainFrame,
            source == origin,
            data.count <= Self.maximumMessageBytes,
            let message = try? JSONDecoder().decode(BridgeMessage.self, from: data),
            message.version == BridgeMessage.supportedVersion,
            message.slug == slug,
            !message.presentationId.isEmpty,
            message.presentationId.count <= Self.maximumPresentationIDCharacters,
            validateAndBindIdentity(from: message)
        else {
            return .ignored
        }

        // Each message becomes one action for the native presentation owner.
        switch message.type {
        case "ready":
            ready = true
            return .ready

        case "visualReady":
            guard ready, !visualReady else {
                return .ignored
            }

            visualReady = true
            return .visualReady

        case "layout":
            guard ready, let layout = message.layout, layout.isValid else {
                return .ignored
            }

            return .layout(layout)

        case "state":
            guard
                ready,
                !accepted,
                let state = message.state,
                state.slug == slug,
                state.visitorId == visitor,
                state.sessionId == session,
                state.surveyId == survey,
                state.updatedAt >= latestStateTimestamp,
                (try? state.validate(now: now)) != nil
            else {
                return .ignored
            }

            // Acceptance can arrive before the page's final animation and `completed` message.
            // Remember it now so a close or cancellation during that animation still completes.
            if state.skyraState.state == .completed {
                accepted = true
            }
            latestStateTimestamp = state.updatedAt
            return .state(state)

        case "completed", "rejected":
            if !ready {
                return .ignored
            }

            if message.type == "completed" {
                accepted = true
            }
            // Once the hosted page confirms acceptance, rejection cannot downgrade completion.
            return .terminal(accepted ? .completed : .rejected)

        case "error":
            guard let code = message.code else {
                return .ignored
            }

            if message.recoverable == true && !Self.fatalErrorCodes.contains(code) {
                return .recoverable(code)
            }
            return .terminal(code == "survey_unavailable" ? .unavailable : .failure(code))

        default:
            return .ignored
        }
    }

    /// receive calls this after decoding: establish the page's identity once, then reject messages from
    /// another presentation. Early initialization errors can omit identity and never establish it.
    private func validateAndBindIdentity(from message: BridgeMessage) -> Bool {
        let isInitializationError = message.type == "error"
            && message.presentationId == "initialization"
            && !ready

        if isInitializationError {
            // A page can fail before it has IDs. Check any supplied IDs without binding them.
            if let visitorID = message.visitorId, visitorID != visitor {
                return false
            }
            if let sessionID = message.sessionId, sessionID != session {
                return false
            }
            if let surveyID = message.surveyId, UUID(uuidString: surveyID) == nil {
                return false
            }
            return true
        }

        guard
            message.visitorId == visitor,
            message.sessionId == session,
            let surveyID = message.surveyId,
            UUID(uuidString: surveyID) != nil
        else {
            return false
        }

        if let survey, survey != surveyID {
            return false
        }
        if let presentation, presentation != message.presentationId {
            return false
        }
        if presentation == nil && message.type != "ready" && message.type != "error" {
            return false
        }

        presentation = message.presentationId
        survey = surveyID
        return true
    }
}
