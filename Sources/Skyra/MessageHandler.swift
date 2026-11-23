// Receives what the Skyra widget in a web view saves, and stores it, so apps don't write their own handler.
#if canImport(WebKit)
import WebKit

public extension Skyra {
    /// Receives everything the Skyra widget saves in your web view and stores it with `sync(_:)`.
    /// Register it under `Skyra.messageHandlerName`:
    ///
    ///     configuration.userContentController.add(skyra.messageHandler, name: Skyra.messageHandlerName)
    ///
    /// Messages from embedded frames are ignored, so only your page can write state.
    var messageHandler: WKScriptMessageHandler {
        SkyraMessageHandler(skyra: self)
    }
}

final class SkyraMessageHandler: NSObject, WKScriptMessageHandler {
    private let skyra: Skyra

    init(skyra: Skyra) {
        self.skyra = skyra
    }

    func userContentController(
        _ controller: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard
            message.frameInfo.isMainFrame,
            let state = try? SkyraState(widget: message.body)
        else {
            return
        }

        _ = try? skyra.sync(state)
    }
}
#endif
