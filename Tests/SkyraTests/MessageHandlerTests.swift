#if canImport(WebKit)
import WebKit
import XCTest
@testable import Skyra

/// The SDK's own handler stores what a page posts, the way the widget posts it, and ignores embedded frames.
@MainActor
final class MessageHandlerTests: XCTestCase {
    private let posted = """
    {"state":{"_id":"\(Fixture.olderVisitor)","org/feedback":{"state":"Completed","lastSync":\(Fixture.now)}},"progress":{}}
    """

    private func load(
        _ html: String,
        into sdk: Skyra,
        listener: SkyraSurveyListener? = nil
    ) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let handler = listener.map { sdk.messageHandler(listener: $0) } ?? sdk.messageHandler
        configuration.userContentController.add(handler, name: Skyra.messageHandlerName)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.loadHTMLString(html, baseURL: URL(string: "https://app.example.com")!)
        return webView
    }

    private func waitUntil(_ condition: () throws -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if (try? condition()) == true {
                return
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    func testAMessageFromThePageIsStored() throws {
        let sdk = try Fixture.sdk()
        let webView = load("""
        <script>window.webkit.messageHandlers.skyra.postMessage(\(posted))</script>
        """, into: sdk)

        waitUntil { try sdk.state().surveys["org/feedback"] != nil }

        XCTAssertEqual(try sdk.state().surveys["org/feedback"]?.state, .completed)
        XCTAssertEqual(try sdk.state().visitorId, Fixture.olderVisitor)
        _ = webView
    }

    func testTheListenerHearsEachChangeOnce() throws {
        final class Listener: SkyraSurveyListener {
            var heard: [String] = []
            func surveyDidChange(_ slug: String, to state: SkyraState.Status) {
                heard.append("\(slug)=\(state.rawValue)")
            }
        }
        let sdk = try Fixture.sdk()
        let listener = Listener()
        let post = "window.webkit.messageHandlers.skyra.postMessage(\(posted))"
        let webView = load("<script>\(post);\(post)</script>", into: sdk, listener: listener)

        waitUntil { !listener.heard.isEmpty }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        XCTAssertEqual(listener.heard, ["org/feedback=Completed"], "Stored first, then told once")
        XCTAssertEqual(try sdk.state().surveys["org/feedback"]?.state, .completed)
        _ = webView
    }

    func testAMessageFromAnEmbeddedFrameIsIgnored() throws {
        let sdk = try Fixture.sdk()
        let frame = "<script>window.webkit.messageHandlers.skyra.postMessage(\(posted))</script>"
            .replacingOccurrences(of: "\"", with: "&quot;")
        let webView = load("""
        <iframe srcdoc="\(frame)"></iframe>
        <script>setTimeout(() => window.webkit.messageHandlers.skyra.postMessage("done"), 500)</script>
        """, into: sdk)

        // The page's own "done" message is not a state; once it has arrived, so has the frame's.
        RunLoop.main.run(until: Date().addingTimeInterval(2))

        XCTAssertNil(try sdk.state().surveys["org/feedback"])
        _ = webView
    }
}
#endif
