#if canImport(UIKit)
import XCTest
import UIKit
import WebKit
import SwiftUI
@testable import Skyra

/// Contract tests for the installation-owned, explicit following request API.
@MainActor
final class FollowingSurveyTests: XCTestCase {
    @MainActor
    private final class SwiftUIModel: ObservableObject {
        @Published var showSheet = false
        @Published var sheetAppeared = false
        @Published var screenAppeared = false
    }

    @MainActor
    private struct SwiftUIFollowingScreen: View {
        @Environment(\.skyraInstallation) private var installation
        @ObservedObject var model: SwiftUIModel
        let appeared: (SkyraInstallation) -> Void

        var body: some View {
            Text("Following host")
                .onAppear {
                    model.screenAppeared = true
                    if let installation {
                        appeared(installation)
                    }
                }
                .sheet(isPresented: $model.showSheet) {
                    Text("Temporary sheet")
                        .onAppear { model.sheetAppeared = true }
                        .onDisappear { model.sheetAppeared = false }
                }
        }
    }

    private struct HostedSDK {
        let sdk: Skyra
        let installation: SkyraInstallation
        let root: SkyraRootViewController
        let window: UIWindow
    }

    @MainActor
    private final class DisappearanceProbeViewController: UIViewController {
        private(set) var didDisappear = false
        var onDisappear: (() -> Void)?

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            didDisappear = true
            onDisappear?()
        }
    }

    @MainActor
    private final class DelayGate {
        private(set) var durations: [UInt64] = []
        private var continuations: [CheckedContinuation<Void, Error>?] = []
        private var cancelledBeforeContinuation: Set<Int> = []
        private let cancellationAware: Bool
        private(set) var cancellationCount = 0

        init(cancellationAware: Bool = true) {
            self.cancellationAware = cancellationAware
        }

        func wait(_ nanoseconds: UInt64) async throws {
            let index = durations.count
            let respondsToCancellation = cancellationAware
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, Error>) in
                    durations.append(nanoseconds)
                    continuations.append(nil)
                    if cancelledBeforeContinuation.remove(index) != nil {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuations[index] = continuation
                    }
                }
            } onCancel: {
                guard respondsToCancellation else {
                    return
                }

                Task { @MainActor [weak self] in self?.cancel(index) }
            }
        }

        func resume(_ index: Int) {
            guard
                continuations.indices.contains(index),
                let continuation = continuations[index]
            else {
                return
            }

            continuation.resume()
            continuations[index] = nil
        }

        private func cancel(_ index: Int) {
            cancellationCount += 1
            guard continuations.indices.contains(index) else {
                cancelledBeforeContinuation.insert(index)
                return
            }
            guard let continuation = continuations[index] else {
                return
            }

            continuations[index] = nil
            continuation.resume(throwing: CancellationError())
        }
    }

    private func makeHostedSDK(
        content: UIViewController,
        active: Bool = true,
        configuration: SkyraConfiguration = .init(persistence: .ephemeral),
        onError: ((Error) -> Void)? = nil,
        window suppliedWindow: UIWindow? = nil
    ) throws -> HostedSDK {
        let root = SkyraRootViewController(content: content)
        let window = suppliedWindow ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root
        let installation = Skyra.install(
            in: window,
            configuration: configuration,
            onError: onError
        )
        let sdk = try XCTUnwrap(installation.sdk)
        sdk.loadHostedPage = { _, _ in }
        sdk.loadPolicy = { _, _ in PresentationPolicy(
            capturePercent: 100,
            minTimeForRetake: 0,
            minTimeForRetrigger: 0
        ) }
        window.makeKeyAndVisible()
        if let scene = window.windowScene {
            NotificationCenter.default.post(name: UIScene.didActivateNotification, object: scene)
        }
        installation.setActive(active)
        return HostedSDK(sdk: sdk, installation: installation, root: root, window: window)
    }

    private func waitForPopup(_ sdk: Skyra) async throws -> SurveyController {
        let deadline = Date().addingTimeInterval(10)
        while sdk.active == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        return try XCTUnwrap(sdk.active, "Following request did not attach a popup")
    }

    private func reveal(_ popup: SurveyController) async throws {
        let helper = BridgeTests()
        let identity: [String: Any] = [
            "visitorId": popup.bridge.visitor,
            "sessionId": popup.bridge.session,
            "slug": popup.bridge.slug,
        ]
        let ready = try helper.receive(popup.bridge, "ready", identity)
        if case .ready = ready {} else {
            XCTFail("Popup bridge must accept ready: \(ready)")
        }
        let visualReady = try helper.receive(popup.bridge, "visualReady", identity)
        if case .visualReady = visualReady {
        } else {
            XCTFail("Popup bridge must accept visualReady: \(visualReady)")
        }
        popup.detectVisualReadiness(true)
        popup.applyLayout(PopupLayout(
            contentHeight: 220,
            cornerRadius: 16,
            minimized: false,
            webControls: true
        ))
        await DecisionTests().flush()
        XCTAssertTrue(popup.revealed)
    }

    private func assertWebViewHitTarget(
        _ popup: SurveyController,
        in hostView: UIView,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let point = popup.webView.convert(
            CGPoint(x: popup.webView.bounds.midX, y: popup.webView.bounds.midY),
            to: hostView
        )
        let hit = hostView.hitTest(point, with: nil)
        XCTAssertNotNil(hit, "The hosted WebView must receive a real hit", file: file, line: line)
        XCTAssertTrue(
            hit === popup.webView || hit?.isDescendant(of: popup.webView) == true,
            "Hit target must be the hosted WebView or one of its descendants",
            file: file,
            line: line
        )
    }

    private func isWebViewHitTarget(_ hit: UIView?, webView: WKWebView) -> Bool {
        hit === webView || hit?.isDescendant(of: webView) == true
    }

    private func waitForSwiftUISheet(
        _ milestone: String,
        condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(condition(), "SwiftUI sheet \(milestone) timed out")
    }

    func testDroppedHandleDoesNotCancelAndNavigationRetainsLivePopup() async throws {
        let home = UIViewController()
        let navigation = UINavigationController(rootViewController: home)
        let hosted = try makeHostedSDK(content: navigation)
        let sdk = hosted.sdk
        let installation = hosted.installation
        var outcomes: [SkyraResult] = []
        var handle: SkyraSurveyRequest? = installation.presentSurvey(
            slug: "org/following",
            onOutcome: { outcomes.append($0) }
        )
        let popup = try await waitForPopup(sdk)
        try await reveal(popup)
        let webView = popup.webView
        let session = popup.bridge.session
        handle = nil
        XCTAssertNil(handle)

        navigation.pushViewController(UIViewController(), animated: false)
        let pushed = try await waitForPopup(sdk)
        await DecisionTests().flush()
        XCTAssertTrue(
            sdk.active === popup,
            "Following ownership must outlive the triggering screen"
        )
        XCTAssertTrue(pushed === popup)
        XCTAssertTrue(popup.webView === webView)
        XCTAssertEqual(popup.bridge.session, session)
        XCTAssertTrue(popup.revealed)
        XCTAssertTrue(popup.view.window === hosted.window)
        XCTAssertTrue(popup.parent === hosted.root)
        XCTAssertTrue(popup.view.superview === hosted.root.view)
        XCTAssertTrue(
            hosted.root.view.subviews.last === popup.view,
            "Popup must stay above pushed content"
        )
        assertWebViewHitTarget(popup, in: popup.view)
        let blankHit = hosted.root.view.hitTest(CGPoint(x: 5, y: 5), with: nil)
        XCTAssertNotNil(blankHit, "Blank overlay space should still reach app content")
        XCTAssertTrue(
            blankHit === hosted.root.content.view
                || blankHit?.isDescendant(of: hosted.root.content.view) == true,
            "Blank overlay space must pass the hit to app content"
        )
        XCTAssertTrue(outcomes.isEmpty, "Navigation is not a terminal outcome in following mode")

        navigation.popViewController(animated: false)
        await DecisionTests().flush()
        XCTAssertTrue(sdk.active === popup)
        XCTAssertTrue(popup.view.window === hosted.window)
        XCTAssertTrue(hosted.root.view.subviews.last === popup.view)

        installation.dismissSurvey()
        try await waitUntil { sdk.active == nil && outcomes.count == 1 }
        XCTAssertEqual(outcomes, [.rejected])
        XCTAssertNil(sdk.followingLifetime)
        hosted.window.isHidden = true
    }

    func testSynchronousDuplicateAndDirectRequestCannotStealFollowingSlot() async throws {
        let hosted = try makeHostedSDK(content: UIViewController(), active: false)
        let sdk = hosted.sdk
        let installation = hosted.installation
        let firstOutcome = expectation(description: "first request interrupted")
        var firstResults: [SkyraResult] = []
        let first = installation.presentSurvey(slug: "org/first") { result in
            firstResults.append(result)
            firstOutcome.fulfill()
        }
        var duplicateErrors: [Error] = []
        let duplicate = installation.presentSurvey(
            slug: "org/second",
            onError: { duplicateErrors.append($0) }
        )
        XCTAssertEqual(duplicateErrors.count, 1)
        XCTAssertEqual(duplicateErrors.first as? SkyraError, .alreadyPresenting)
        XCTAssertNotNil(sdk.pendingPresentation, "The pending request reserves the SDK slot")
        XCTAssertNil(sdk.active)
        XCTAssertNil(try sdk.store.storage.update(key: sdk.store.key) { $0 })
        XCTAssertTrue(firstResults.isEmpty)

        do {
            _ = try await sdk.presentSurvey(slug: "org/direct")
            XCTFail("The ordinary SDK API must share the occupied request slot")
        } catch {
            XCTAssertEqual(error as? SkyraError, .alreadyPresenting)
        }
        first.cancel()
        await fulfillment(of: [firstOutcome], timeout: 5)
        XCTAssertEqual(firstResults, [.interrupted])
        XCTAssertNil(sdk.pendingPresentation)
        hosted.window.isHidden = true
        _ = duplicate
    }

    func testNotShownScreenVisitLeavesFollowingPopupVisibleAndUntouched() async throws {
        for blockedReason: SkyraNotShownReason in [
            .unavailable,
            .captureNotSelected,
            .rejectedCooldown,
            .completedCooldown,
        ] {
            let configuration = SkyraConfiguration(
                persistence: .ephemeral,
                surveyDecision: { context in
                    if context.requestedSlug == "org/b" {
                        return .notShown(blockedReason)
                    }
                    return .present(slug: "org/a")
                }
            )
            let content = UIViewController()
            let hosted = try makeHostedSDK(content: content, configuration: configuration)
            defer { hosted.window.isHidden = true }
            var aOutcomes: [SkyraResult] = []
            let handle = hosted.installation.presentSurvey(
                slug: "org/a",
                onOutcome: { aOutcomes.append($0) }
            )
            let a = try await waitForPopup(hosted.sdk)
            let aWebView = a.webView

            let bResult = try await hosted.sdk.presentScreenSurvey(
                slug: "org/b",
                from: content,
                visit: UUID()
            )

            XCTAssertEqual(bResult, .notShown(reason: blockedReason))
            XCTAssertTrue(hosted.sdk.active === a)
            XCTAssertTrue(a.webView === aWebView)
            XCTAssertFalse(a.view.isHidden)
            XCTAssertNil(hosted.sdk.parkedFollowing)
            XCTAssertNil(hosted.sdk.screenPriorityVisit)
            XCTAssertTrue(aOutcomes.isEmpty)
            XCTAssertNotNil(hosted.sdk.followingLifetime)
            handle.cancel()
        }
    }

    func testScreenDecisionFailureLeavesFollowingPopupVisibleAndUntouched() async throws {
        let configuration = SkyraConfiguration(
            persistence: .ephemeral,
            surveyDecision: { context in
                if context.requestedSlug == "org/b" {
                    throw URLError(.notConnectedToInternet)
                }
                return .present(slug: "org/a")
            }
        )
        let content = UIViewController()
        let hosted = try makeHostedSDK(content: content, configuration: configuration)
        defer { hosted.window.isHidden = true }
        var outcomes: [SkyraResult] = []
        let handle = hosted.installation.presentSurvey(
            slug: "org/a",
            onOutcome: { outcomes.append($0) }
        )
        let a = try await waitForPopup(hosted.sdk)
        let aWebView = a.webView

        do {
            _ = try await hosted.sdk.presentScreenSurvey(
                slug: "org/b",
                from: content,
                visit: UUID()
            )
            XCTFail("The injected selection failure must propagate")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }

        XCTAssertTrue(hosted.sdk.active === a)
        XCTAssertTrue(a.webView === aWebView)
        XCTAssertFalse(a.view.isHidden)
        XCTAssertNil(hosted.sdk.parkedFollowing)
        XCTAssertNil(hosted.sdk.screenPriorityVisit)
        XCTAssertTrue(outcomes.isEmpty)
        handle.cancel()
    }

    func testFollowingPopupRemainsVisibleThroughoutScreenRequestDelay() async throws {
        let gate = DelayGate()
        let configuration = SkyraConfiguration(
            persistence: .ephemeral,
            surveyDecision: { context in
                .present(
                    slug: context.requestedSlug ?? "org/a",
                    initialDelayMilliseconds: context.requestedSlug == "org/b" ? 250 : 0
                )
            }
        )
        let content = UIViewController()
        let hosted = try makeHostedSDK(content: content, configuration: configuration)
        hosted.sdk.waitForDelay = { try await gate.wait($0) }
        defer { hosted.window.isHidden = true }
        var outcomes: [SkyraResult] = []
        let handle = hosted.installation.presentSurvey(
            slug: "org/a",
            onOutcome: { outcomes.append($0) }
        )
        let a = try await waitForPopup(hosted.sdk)
        let originalWebView = a.webView
        let visit = UUID()
        let bTask = Task {
            try await hosted.sdk.presentScreenSurvey(slug: "org/b", from: content, visit: visit)
        }
        try await waitUntil { gate.durations.count == 1 }

        XCTAssertTrue(hosted.sdk.active === a)
        XCTAssertTrue(a.webView === originalWebView)
        XCTAssertFalse(a.view.isHidden)
        XCTAssertNil(hosted.sdk.parkedFollowing)
        XCTAssertNil(hosted.sdk.screenPriorityVisit)
        XCTAssertTrue(outcomes.isEmpty)

        bTask.cancel()
        _ = try? await bTask.value
        XCTAssertTrue(hosted.sdk.active === a)
        XCTAssertTrue(a.webView === originalWebView)
        XCTAssertTrue(outcomes.isEmpty)
        handle.cancel()
    }

    func testScreenVisitDelayPausesAndIgnoresLateSleeperAfterSceneInactivity() async throws {
        let gate = DelayGate(cancellationAware: false)
        let configuration = SkyraConfiguration(
            persistence: .ephemeral,
            surveyDecision: { context in
                .present(
                    slug: context.requestedSlug ?? "org/a",
                    initialDelayMilliseconds: context.requestedSlug == "org/b" ? 500 : 0
                )
            }
        )
        let content = UIViewController()
        let hosted = try makeHostedSDK(content: content, configuration: configuration)
        var clock = 100.0
        hosted.sdk.followingNow = { clock }
        hosted.sdk.waitForDelay = { try await gate.wait($0) }
        defer { hosted.window.isHidden = true }
        var aOutcomes: [SkyraResult] = []
        let handle = hosted.installation.presentSurvey(
            slug: "org/a",
            onOutcome: { aOutcomes.append($0) }
        )
        let a = try await waitForPopup(hosted.sdk)
        let aWebView = a.webView
        let visit = UUID()
        let bTask = Task {
            try await hosted.sdk.presentScreenSurvey(slug: "org/b", from: content, visit: visit)
        }
        try await waitUntil { gate.durations.count == 1 }
        XCTAssertTrue(hosted.sdk.active === a)
        XCTAssertFalse(a.view.isHidden)
        XCTAssertNil(hosted.sdk.screenCandidateController)

        hosted.installation.setActive(false)
        XCTAssertTrue(hosted.sdk.active === a)
        XCTAssertTrue(a.view.isHidden, "Scene inactivity suspends A without ending it")
        clock += 10
        gate.resume(0) // This injected sleeper ignores cancellation; its stale reply must be inert.
        await Task.yield()

        hosted.installation.setActive(true)
        try await waitUntil { gate.durations.count == 2 }
        XCTAssertEqual(gate.durations[1], 500_000_000)
        XCTAssertNil(
            hosted.sdk.screenCandidateController,
            "The stale sleeper cannot finish B's delay"
        )
        XCTAssertTrue(hosted.sdk.active === a)
        XCTAssertFalse(a.view.isHidden)

        clock += 0.5
        gate.resume(1)
        try await waitUntil { hosted.sdk.screenCandidateController != nil }
        XCTAssertTrue(hosted.sdk.active === a)
        XCTAssertTrue(a.webView === aWebView)
        XCTAssertTrue(aOutcomes.isEmpty)
        hosted.sdk.endScreenVisit(visit)
        _ = try? await bTask.value
        handle.cancel()
    }

    func testScreenVisitDelayFailureReleasesCandidateWithoutChangingFollowingPopup() async throws {
        let configuration = SkyraConfiguration(
            persistence: .ephemeral,
            surveyDecision: { context in
                .present(
                    slug: context.requestedSlug ?? "org/a",
                    initialDelayMilliseconds: context.requestedSlug == "org/b" ? 1 : 0
                )
            }
        )
        let content = UIViewController()
        let hosted = try makeHostedSDK(content: content, configuration: configuration)
        hosted.sdk.waitForDelay = { _ in throw URLError(.timedOut) }
        defer { hosted.window.isHidden = true }
        var outcomes: [SkyraResult] = []
        let handle = hosted.installation.presentSurvey(
            slug: "org/a",
            onOutcome: { outcomes.append($0) }
        )
        let a = try await waitForPopup(hosted.sdk)

        do {
            _ = try await hosted.sdk.presentScreenSurvey(
                slug: "org/b",
                from: content,
                visit: UUID()
            )
            XCTFail("A genuine screen delay error must propagate")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        XCTAssertTrue(hosted.sdk.active === a)
        XCTAssertFalse(a.view.isHidden)
        XCTAssertNil(hosted.sdk.screenCandidateVisit)
        XCTAssertNil(hosted.sdk.screenPriorityVisit)
        XCTAssertTrue(outcomes.isEmpty)
        handle.cancel()
    }

    func testShownScreenLeaseRetainsFollowingPopupUntilVisitDeparture() async throws {
        for bResult: SkyraResult in [.completed, .rejected] {
            let configuration = SkyraConfiguration(
                persistence: .ephemeral,
                surveyDecision: { context in .present(slug: context.requestedSlug ?? "org/a") }
            )
            let content = UIViewController()
            let hosted = try makeHostedSDK(content: content, configuration: configuration)
            defer { hosted.window.isHidden = true }
            var aOutcomes: [SkyraResult] = []
            let aHandle = hosted.installation.presentSurvey(
                slug: "org/a",
                onOutcome: { aOutcomes.append($0) }
            )
            let a = try await waitForPopup(hosted.sdk)
            try await reveal(a)
            let aWebView = a.webView
            let aSession = a.bridge.session
            let visit = UUID()
            let bTask = Task {
                try await hosted.sdk.presentScreenSurvey(slug: "org/b", from: content, visit: visit)
            }
            try await waitUntil { hosted.sdk.screenCandidateController != nil }
            let b = try XCTUnwrap(hosted.sdk.screenCandidateController)
            try await reveal(b)

            XCTAssertTrue(hosted.sdk.active === b)
            XCTAssertTrue(hosted.sdk.parkedFollowing === a)
            XCTAssertTrue(a.view.isHidden)
            XCTAssertTrue(a.webView === aWebView)
            XCTAssertEqual(a.bridge.session, aSession)
            XCTAssertTrue(aOutcomes.isEmpty)

            b.finish(.success(bResult), rejected: bResult == .rejected)
            let shownResult = try await bTask.value
            XCTAssertEqual(shownResult, bResult)
            try await waitUntil { hosted.sdk.active == nil }
            XCTAssertEqual(hosted.sdk.screenPriorityVisit, visit)
            XCTAssertTrue(hosted.sdk.parkedFollowing === a)
            XCTAssertTrue(a.view.isHidden)
            XCTAssertTrue(aOutcomes.isEmpty)

            hosted.sdk.endScreenVisit(visit)
            XCTAssertTrue(hosted.sdk.active === a)
            XCTAssertNil(hosted.sdk.parkedFollowing)
            XCTAssertFalse(a.view.isHidden)
            XCTAssertTrue(a.webView === aWebView)
            XCTAssertEqual(a.bridge.session, aSession)
            XCTAssertTrue(aOutcomes.isEmpty)
            aHandle.cancel()
        }
    }

    func testActiveScreenDepartureInterruptsBAndRestoresSameFollowingController() async throws {
        let configuration = SkyraConfiguration(
            persistence: .ephemeral,
            surveyDecision: { context in .present(slug: context.requestedSlug ?? "org/a") }
        )
        let content = UIViewController()
        let hosted = try makeHostedSDK(content: content, configuration: configuration)
        defer { hosted.window.isHidden = true }
        var aOutcomes: [SkyraResult] = []
        let aHandle = hosted.installation.presentSurvey(
            slug: "org/a",
            onOutcome: { aOutcomes.append($0) }
        )
        let a = try await waitForPopup(hosted.sdk)
        try await reveal(a)
        let aWebView = a.webView
        let aSession = a.bridge.session
        var bOutcomes: [SkyraResult] = []
        let visit = UUID()
        let bTask = Task {
            try await hosted.sdk.presentScreenSurvey(slug: "org/b", from: content, visit: visit)
        }
        try await waitUntil { hosted.sdk.screenCandidateController != nil }
        let b = try XCTUnwrap(hosted.sdk.screenCandidateController)
        try await reveal(b)
        XCTAssertTrue(hosted.sdk.parkedFollowing === a)

        hosted.sdk.endScreenVisit(visit)
        let bResult = try await bTask.value
        XCTAssertEqual(bResult, .interrupted)
        try await waitUntil { hosted.sdk.active === a }
        XCTAssertNil(hosted.sdk.parkedFollowing)
        XCTAssertNil(hosted.sdk.screenPriorityVisit)
        XCTAssertFalse(a.view.isHidden)
        XCTAssertTrue(a.webView === aWebView)
        XCTAssertEqual(a.bridge.session, aSession)
        XCTAssertTrue(aOutcomes.isEmpty)
        aHandle.cancel()
    }

    func testUIKitScreenAttachmentOwnsShownLeaseUntilNavigationDeparture() async throws {
        let configuration = SkyraConfiguration(
            persistence: .ephemeral,
            surveyDecision: { context in .present(slug: context.requestedSlug ?? "org/a") }
        )
        let home = UIViewController()
        let navigation = UINavigationController(rootViewController: home)
        let window = try PresentationTests().sceneWindow()
        let hosted = try makeHostedSDK(
            content: navigation,
            configuration: configuration,
            window: window
        )
        defer { hosted.window.isHidden = true }
        var aOutcomes: [SkyraResult] = []
        let aHandle = hosted.installation.presentSurvey(
            slug: "org/a",
            onOutcome: { aOutcomes.append($0) }
        )
        let a = try await waitForPopup(hosted.sdk)
        try await reveal(a)
        let aWebView = a.webView
        let aSession = a.bridge.session
        var bOutcomes: [SkyraResult] = []
        let bScreen = UIViewController()
        let attachment = bScreen.skyraSurvey("org/b", onOutcome: { bOutcomes.append($0) })
        defer { attachment.detach() }
        navigation.pushViewController(bScreen, animated: false)
        try await waitUntil { hosted.sdk.screenCandidateController != nil }
        let b = try XCTUnwrap(hosted.sdk.screenCandidateController)
        try await reveal(b)
        XCTAssertTrue(hosted.sdk.active === b)
        XCTAssertTrue(hosted.sdk.parkedFollowing === a)
        XCTAssertTrue(a.view.isHidden)

        navigation.pushViewController(UIViewController(), animated: false)
        try await waitUntil { hosted.sdk.active === a && bOutcomes == [.interrupted] }
        XCTAssertNil(hosted.sdk.parkedFollowing)
        XCTAssertNil(hosted.sdk.screenPriorityVisit)
        XCTAssertFalse(a.view.isHidden)
        XCTAssertTrue(a.webView === aWebView)
        XCTAssertEqual(a.bridge.session, aSession)
        XCTAssertTrue(aOutcomes.isEmpty)
        aHandle.cancel()
    }

    func testHandleCancellationIsScopedAndFinalCallbackCanStartNextRequest() async throws {
        let host = UIViewController()
        let hosted = try makeHostedSDK(content: host)
        let sdk = hosted.sdk
        let installation = hosted.installation
        var outcomes: [SkyraResult] = []
        var second: SkyraSurveyRequest?
        var slotWasFreeBeforeSuccessor = false
        var successorErrors: [Error] = []
        let first = installation.presentSurvey(
            slug: "org/first",
            onOutcome: { result in
                outcomes.append(result)
                XCTAssertEqual(result, .interrupted)
                XCTAssertNil(sdk.active)
                XCTAssertNil(sdk.pendingPresentation)
                XCTAssertNil(sdk.followingLifetime)
                slotWasFreeBeforeSuccessor = true
                second = installation.presentSurvey(
                    slug: "org/second",
                    onOutcome: { outcomes.append($0) },
                    onError: { successorErrors.append($0) }
                )
            },
            onError: { XCTFail("Unexpected first-request error: \($0)") }
        )
        let firstPopup = try await waitForPopup(sdk)
        try await reveal(firstPopup)
        first.cancel()
        try await waitUntil { outcomes == [.interrupted] && sdk.active?.bridge.slug == "org/second"
        }
        XCTAssertTrue(slotWasFreeBeforeSuccessor)
        XCTAssertTrue(successorErrors.isEmpty)
        let secondPopup = try await waitForPopup(sdk)
        try await reveal(secondPopup)
        XCTAssertEqual(secondPopup.bridge.slug, "org/second")

        // A previously cancelled request handle cannot affect its successor.
        first.cancel()
        XCTAssertTrue(sdk.active === secondPopup)
        XCTAssertFalse(firstPopup === secondPopup)
        installation.dismissSurvey()
        try await waitUntil { sdk.active == nil && outcomes.count == 2 }
        XCTAssertEqual(outcomes, [.interrupted, .rejected])
        withExtendedLifetime(second) {}
        hosted.window.isHidden = true
    }

    func testFollowingLifetimeDelayCountsEligibleTimeOnly() async throws {
        let hosted = try makeHostedSDK(content: UIViewController())
        let sdk = hosted.sdk
        let installation = hosted.installation
        var time: TimeInterval = 0
        sdk.followingNow = { time }
        let sleeper = DelayGate(cancellationAware: false)
        sdk.waitForDelay = { try await sleeper.wait($0) }
        sdk.loadPolicy = { _, _ in PresentationPolicy(
            capturePercent: 100,
            minTimeForRetake: 0,
            minTimeForRetrigger: 0,
            initialDelayMilliseconds: 5_000
        ) }

        var outcomes: [SkyraResult] = []
        let request = installation.presentSurvey(
            slug: "org/timed",
            onOutcome: { outcomes.append($0) }
        )
        try await waitUntil { sleeper.durations.count == 1 }
        XCTAssertEqual(sleeper.durations, [5_000_000_000])

        time = 2
        installation.setActive(false)
        XCTAssertNil(sdk.active)
        XCTAssertTrue(outcomes.isEmpty)
        time = 102
        installation.setActive(true)
        try await waitUntil { sleeper.durations.count == 2 }
        XCTAssertEqual(sleeper.durations, [5_000_000_000, 3_000_000_000])

        time = 105
        installation.setActive(true)
        let popup = try await waitForPopup(sdk)
        XCTAssertEqual(popup.bridge.slug, "org/timed")
        XCTAssertEqual(outcomes.count, 0)
        // A canceled sleeper may finish late, but cannot attach a duplicate popup.
        sleeper.resume(0)
        sleeper.resume(1)
        await DecisionTests().flush()
        XCTAssertTrue(sdk.active === popup)
        request.cancel()
        try await waitUntil { sdk.active == nil && outcomes == [.interrupted] }
        hosted.window.isHidden = true
    }

    func testInactiveGateCancelsInjectedSleeperAndResumesWithoutCompletingDelay() async throws {
        let hosted = try makeHostedSDK(content: UIViewController())
        let sdk = hosted.sdk
        let installation = hosted.installation
        let sleeper = DelayGate()
        let time: TimeInterval = 0
        sdk.followingNow = { time }
        sdk.waitForDelay = { try await sleeper.wait($0) }
        sdk.loadPolicy = { _, _ in PresentationPolicy(
            capturePercent: 100,
            minTimeForRetake: 0,
            minTimeForRetrigger: 0,
            initialDelayMilliseconds: 5_000
        ) }
        var outcomes: [SkyraResult] = []
        let request = installation.presentSurvey(
            slug: "org/cancelable-timer",
            onOutcome: { outcomes.append($0) }
        )
        try await waitUntil { sleeper.durations.count == 1 }
        installation.setActive(false)
        try await waitUntil { sleeper.cancellationCount == 1 }
        XCTAssertNil(sdk.active)
        XCTAssertTrue(outcomes.isEmpty)

        installation.setActive(true)
        try await waitUntil { sleeper.durations.count == 2 }
        XCTAssertEqual(sleeper.durations, [5_000_000_000, 5_000_000_000])
        request.cancel()
        try await waitUntil { sdk.active == nil && outcomes == [.interrupted] }
        XCTAssertGreaterThanOrEqual(sleeper.cancellationCount, 2)
        hosted.window.isHidden = true
    }

    func testRootReplacementWhileInactiveEndsRequestAndDoesNotReopenOnActivation() async throws {
        let hosted = try makeHostedSDK(content: UIViewController(), active: false)
        var lookups = 0
        hosted.sdk.loadPolicy = { _, _ in
            lookups += 1
            return PresentationPolicy(
                capturePercent: 100,
                minTimeForRetake: 0,
                minTimeForRetrigger: 0
            )
        }
        var outcomes: [SkyraResult] = []
        _ = hosted.installation.presentSurvey(
            slug: "org/root-replaced",
            onOutcome: { outcomes.append($0) }
        )
        await DecisionTests().flush()
        XCTAssertEqual(lookups, 1, "Native preflight may finish while the host is inactive")
        let lookupsAfterPreflight = lookups
        hosted.window.rootViewController = UIViewController()
        try await waitUntil { outcomes == [.interrupted] }
        XCTAssertNil(hosted.sdk.followingLifetime)
        hosted.installation.setActive(true)
        await DecisionTests().flush()
        XCTAssertEqual(
            lookups,
            lookupsAfterPreflight,
            "A replacement root must not silently restart a following request"
        )
        XCTAssertEqual(outcomes, [.interrupted])
        XCTAssertNil(hosted.sdk.active)
        XCTAssertNil(try hosted.sdk.store.storage.update(key: hosted.sdk.store.key) { $0 })
        hosted.window.isHidden = true
    }

    func testFollowingLifetimeSurvivesContentViewDetachmentInsideStableRoot() throws {
        let host = UIViewController()
        let hosted = try makeHostedSDK(content: host)
        let lifetime = FollowingLifetime(sdk: hosted.sdk, now: { 0 })
        lifetime.start()
        XCTAssertTrue(lifetime.available)
        let contentView = hosted.root.content.view!
        contentView.removeFromSuperview()
        lifetime.refresh()
        XCTAssertTrue(lifetime.available, "The explicit outer host remains attached")
        XCTAssertFalse(lifetime.invalidated)
        hosted.root.view.addSubview(contentView)
        lifetime.refresh()
        XCTAssertTrue(lifetime.available)
        XCTAssertFalse(lifetime.invalidated)
        lifetime.stop()
        hosted.window.isHidden = true
    }

    func testFollowingPopupStaysTopmostAndInteractiveAcrossTabSelection() async throws {
        let first = UIViewController()
        let second = UIViewController()
        let tabs = UITabBarController()
        tabs.setViewControllers([first, second], animated: false)
        tabs.selectedViewController = first
        let hosted = try makeHostedSDK(content: tabs)
        let sdk = hosted.sdk
        let installation = hosted.installation
        defer { hosted.window.isHidden = true }

        var outcomes: [SkyraResult] = []
        let request = installation.presentSurvey(
            slug: "org/tabs",
            onOutcome: { outcomes.append($0) }
        )
        let popup = try await waitForPopup(sdk)
        try await reveal(popup)
        let webView = popup.webView
        let session = popup.bridge.session
        tabs.selectedViewController = second
        await DecisionTests().flush()
        XCTAssertTrue(sdk.active === popup)
        XCTAssertTrue(popup.webView === webView)
        XCTAssertEqual(popup.bridge.session, session)
        XCTAssertTrue(popup.revealed)
        XCTAssertTrue(popup.view.window === hosted.window)
        XCTAssertTrue(popup.parent === hosted.root)
        XCTAssertTrue(popup.view.superview === hosted.root.view)
        XCTAssertTrue(
            hosted.root.view.subviews.last === popup.view,
            "Popup must remain above the selected tab"
        )
        assertWebViewHitTarget(popup, in: popup.view)
        request.cancel()
        try await waitUntil { sdk.active == nil && outcomes == [.interrupted] }
    }

    func testDirectUIKitRequestIsScreenBoundWhileInstallationRequestFollowsRoot() async throws {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive },
            "UIKit navigation lifecycle test requires a foreground-active UIWindowScene"
        )
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let home = DisappearanceProbeViewController()
        let navigation = UINavigationController(rootViewController: home)
        let hosted = try makeHostedSDK(content: navigation, window: window)
        let sdk = hosted.sdk
        let installation = hosted.installation
        defer { hosted.window.isHidden = true }

        let directFinished =
            expectation(description: "Screen-bound UIKit request returns on screen departure")
        var directResult: Result<SkyraResult, Error>?
        let direct = Task {
            do {
                directResult = .success(try await sdk.presentSurvey(slug: "org/screen-bound"))
            } catch {
                directResult = .failure(error)
            }
            directFinished.fulfill()
        }
        let directPopup = try await waitForPopup(sdk)
        try await reveal(directPopup)
        let screenDeparted = expectation(description: "UIKit delivers home screen disappearance")
        home.onDisappear = { [weak home] in
            home?.onDisappear = nil
            screenDeparted.fulfill()
        }
        navigation.pushViewController(UIViewController(), animated: false)
        await fulfillment(of: [screenDeparted], timeout: 5)
        XCTAssertTrue(home.didDisappear, "UIKit must report the requesting screen's departure")
        await fulfillment(of: [directFinished], timeout: 5)
        guard let directResult else {
            XCTFail("Screen-bound request did not complete after its screen disappeared")
            direct.cancel()
            return
        }
        guard case .success(let result) = directResult else {
            if case .failure(let error) = directResult {
                XCTFail("Screen-bound request failed instead of returning interrupted: \(error)")
            }
            return
        }

        XCTAssertEqual(result, .interrupted)
        XCTAssertNil(
            sdk.active,
            "The SDK's direct UIKit API remains owned by its triggering screen"
        )

        navigation.popViewController(animated: false)
        var outcomes: [SkyraResult] = []
        let following = installation.presentSurvey(
            slug: "org/root-owned",
            onOutcome: { outcomes.append($0) }
        )
        let followingPopup = try await waitForPopup(sdk)
        try await reveal(followingPopup)
        let session = followingPopup.bridge.session
        navigation.pushViewController(UIViewController(), animated: false)
        await DecisionTests().flush()
        XCTAssertTrue(sdk.active === followingPopup)
        XCTAssertEqual(followingPopup.bridge.session, session)
        XCTAssertTrue(followingPopup.revealed)
        XCTAssertTrue(followingPopup.view.window === hosted.window)
        XCTAssertTrue(followingPopup.parent === hosted.root)
        XCTAssertTrue(hosted.root.view.subviews.last === followingPopup.view)
        XCTAssertTrue(outcomes.isEmpty)
        following.cancel()
        try await waitUntil { sdk.active == nil && outcomes == [.interrupted] }
    }

    func testFollowingPopupIdentitySurvivesUIKitModalCoverAndReturn() async throws {
        let navigation = UINavigationController(rootViewController: UIViewController())
        let hosted = try makeHostedSDK(content: navigation)
        let sdk = hosted.sdk
        let installation = hosted.installation
        defer { hosted.window.isHidden = true }

        var outcomes: [SkyraResult] = []
        let request = installation.presentSurvey(
            slug: "org/modal",
            onOutcome: { outcomes.append($0) }
        )
        let popup = try await waitForPopup(sdk)
        try await reveal(popup)
        let webView = try XCTUnwrap(popup.webView)
        let session = popup.bridge.session

        for style in [UIModalPresentationStyle.pageSheet, .fullScreen, .overFullScreen] {
            let modal = UIViewController()
            modal.modalPresentationStyle = style
            let presented = expectation(description: "UIKit \(style.rawValue) modal presented")
            navigation.present(modal, animated: false) { presented.fulfill() }
            await fulfillment(of: [presented], timeout: 5)
            XCTAssertNotNil(modal.presentingViewController)
            XCTAssertTrue(modal.view.window === hosted.window)
            let coveredPoint = webView.convert(
                CGPoint(x: webView.bounds.midX, y: webView.bounds.midY),
                to: hosted.window
            )
            let coveredHit = hosted.window.hitTest(coveredPoint, with: nil)
            XCTAssertNotNil(coveredHit, "A UIKit modal should receive the covered hit")
            XCTAssertFalse(isWebViewHitTarget(coveredHit, webView: webView))

            let dismissed = expectation(description: "UIKit \(style.rawValue) modal dismissed")
            modal.dismiss(animated: false) { dismissed.fulfill() }
            await fulfillment(of: [dismissed], timeout: 5)
            XCTAssertTrue(sdk.active === popup)
            XCTAssertTrue(popup.webView === webView)
            XCTAssertEqual(popup.bridge.session, session)
            XCTAssertTrue(popup.revealed)
            XCTAssertTrue(popup.view.window === hosted.window)
            XCTAssertTrue(popup.parent === hosted.root)
            XCTAssertTrue(hosted.root.view.subviews.last === popup.view)
            assertWebViewHitTarget(popup, in: popup.view)
            assertWebViewHitTarget(popup, in: hosted.window)
            XCTAssertTrue(outcomes.isEmpty)
        }
        request.cancel()
        try await waitUntil { sdk.active == nil && outcomes == [.interrupted] }
    }

    func testPublicSwiftUIRootEnvironmentFollowingRequestSurvivesSheetReturn() async throws {
        let model = SwiftUIModel()
        var installation: SkyraInstallation?
        var request: SkyraSurveyRequest?
        var outcomes: [SkyraResult] = []
        var rootErrors: [Error] = []
        let screen = SwiftUIFollowingScreen(model: model) { value in
            guard request == nil else {
                return
            }

            installation = value
            value.sdk?.loadHostedPage = { _, _ in }
            value.sdk?.loadPolicy = { _, _ in PresentationPolicy(
                capturePercent: 100,
                minTimeForRetake: 0,
                minTimeForRetrigger: 0
            ) }
            request = value.presentSurvey(
                slug: "org/swiftui-follow",
                onOutcome: { outcomes.append($0) }
            )
        }
        let root = NavigationView { screen }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .skyra(
                configuration: .init(persistence: .ephemeral),
                onError: { rootErrors.append($0) }
            )
            .environment(\.scenePhase, .active)
        let hosting = UIHostingController(rootView: root)
        let activeScene = try XCTUnwrap(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive },
            "SwiftUI presentation test requires a foreground-active UIWindowScene"
        )
        let window = UIWindow(windowScene: activeScene)
        window.frame = activeScene.coordinateSpace.bounds
        window.rootViewController = hosting
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        try await waitUntil(
            message: "SwiftUI root screen onAppear was not observed in the scene-backed window"
        ) { model.screenAppeared }
        try await waitUntil(
            message: "SwiftUI root onAppear did not receive the Skyra installation"
        ) { installation != nil }
        XCTAssertTrue(rootErrors.isEmpty, "Skyra root initialization failed: \(rootErrors)")
        let sdk = try XCTUnwrap(installation?.sdk)
        let popup = try await waitForPopup(sdk)
        try await reveal(popup)
        let webView = try XCTUnwrap(popup.webView)
        let session = popup.bridge.session
        let overlay = try XCTUnwrap(sdk.followingHost?.controller)
        XCTAssertNotNil(sdk.presenter)
        XCTAssertFalse(
            overlay === sdk.presenter,
            "Following overlay must not replace screen presenter"
        )
        hosting.view.layoutIfNeeded()
        overlay.view.layoutIfNeeded()
        let rootContentFrame = hosting.view.safeAreaLayoutGuide.layoutFrame
        let overlayFrame = overlay.view.convert(overlay.view.bounds, to: hosting.view)
        XCTAssertGreaterThanOrEqual(overlay.view.bounds.width, 300)
        XCTAssertGreaterThanOrEqual(overlay.view.bounds.height, 600)
        XCTAssertGreaterThanOrEqual(overlayFrame.width, rootContentFrame.width - 1)
        XCTAssertGreaterThanOrEqual(overlayFrame.height, rootContentFrame.height - 1)
        XCTAssertNil(
            overlay.view.hitTest(CGPoint(x: 5, y: 5), with: nil),
            "The root overlay must pass empty-space touches through"
        )
        assertWebViewHitTarget(popup, in: overlay.view)
        model.showSheet = true
        try await waitForSwiftUISheet("appearance") { model.sheetAppeared }
        let popupPoint = webView.convert(
            CGPoint(x: webView.bounds.midX, y: webView.bounds.midY),
            to: window
        )
        let sheetHit = window.hitTest(popupPoint, with: nil)
        XCTAssertNotNil(sheetHit, "The presented SwiftUI sheet should receive the covered hit")
        XCTAssertFalse(isWebViewHitTarget(sheetHit, webView: webView))
        model.showSheet = false
        try await waitForSwiftUISheet("dismissal and WebView hit restoration") {
            !model.sheetAppeared
                && isWebViewHitTarget(window.hitTest(popupPoint, with: nil), webView: webView)
        }
        XCTAssertTrue(sdk.active === popup)
        XCTAssertTrue(popup.webView === webView)
        XCTAssertEqual(popup.bridge.session, session)
        XCTAssertTrue(popup.revealed)
        XCTAssertTrue(popup.view.window === window)
        XCTAssertTrue(outcomes.isEmpty)

        request?.cancel()
        try await waitForSwiftUISheet("request cancellation completion") {
            sdk.active == nil && outcomes == [.interrupted]
        }
    }

    func testFollowingAPIPendingDelaySurvivesNavigationAndAttachesOnce() async throws {
        let home = UIViewController()
        let navigation = UINavigationController(rootViewController: home)
        let hosted = try makeHostedSDK(content: navigation)
        let sdk = hosted.sdk
        let installation = hosted.installation
        sdk.loadPolicy = { _, _ in PresentationPolicy(
            capturePercent: 100,
            minTimeForRetake: 0,
            minTimeForRetrigger: 0,
            initialDelayMilliseconds: 5_000
        ) }
        let sleeper = DelayGate()
        sdk.waitForDelay = { try await sleeper.wait($0) }
        var time: TimeInterval = 0
        sdk.followingNow = { time }
        defer { hosted.window.isHidden = true }

        var outcomes: [SkyraResult] = []
        let request = installation.presentSurvey(
            slug: "org/delayed",
            onOutcome: { outcomes.append($0) }
        )
        try await waitUntil { sleeper.durations.count == 1 }
        navigation.pushViewController(UIViewController(), animated: false)
        await DecisionTests().flush()
        XCTAssertNil(sdk.active, "No popup should attach until the delivered delay elapses")
        XCTAssertTrue(outcomes.isEmpty, "Navigation must not terminate a following request")
        navigation.popViewController(animated: false)
        XCTAssertEqual(sleeper.durations, [5_000_000_000])
        time = 5
        installation.setActive(true)
        let popup = try await waitForPopup(sdk)
        XCTAssertEqual(popup.bridge.slug, "org/delayed")
        XCTAssertTrue(sdk.active === popup)
        request.cancel()
        try await waitUntil { sdk.active == nil && outcomes == [.interrupted] }
    }

    func testFollowingRequestWaitsWhileInactiveAndResumesThroughInstallationActivity() async throws {
        let hosted = try makeHostedSDK(content: UIViewController(), active: false)
        let sdk = hosted.sdk
        let installation = hosted.installation
        var lookups = 0
        sdk.loadPolicy = { _, _ in
            lookups += 1
            return PresentationPolicy(
                capturePercent: 100,
                minTimeForRetake: 0,
                minTimeForRetrigger: 0
            )
        }
        var outcomes: [SkyraResult] = []
        let request = installation.presentSurvey(
            slug: "org/inactive",
            onOutcome: { outcomes.append($0) }
        )
        await DecisionTests().flush()
        XCTAssertEqual(
            lookups,
            1,
            "Selection and native policy can finish while the host is inactive"
        )
        XCTAssertNil(sdk.active)
        XCTAssertTrue(outcomes.isEmpty)

        installation.setActive(true)
        let popup = try await waitForPopup(sdk)
        XCTAssertEqual(popup.bridge.slug, "org/inactive")
        XCTAssertEqual(lookups, 1)
        request.cancel()
        try await waitUntil { sdk.active == nil && outcomes == [.interrupted] }
        hosted.window.isHidden = true
    }

    func testPreparedFollowingPopupDoesNotTimeoutWhileInactiveAndRevealsOnResume() async throws {
        let hosted = try makeHostedSDK(content: UIViewController())
        let sdk = hosted.sdk
        let installation = hosted.installation
        var outcomes: [SkyraResult] = []
        let request = installation.presentSurvey(
            slug: "org/readiness",
            onOutcome: { outcomes.append($0) }
        )
        let popup = try await waitForPopup(sdk)
        let webView = popup.webView
        let session = popup.bridge.session
        installation.setActive(false)
        XCTAssertTrue(popup.view.isHidden)

        let helper = BridgeTests()
        let identity: [String: Any] = [
            "visitorId": popup.bridge.visitor,
            "sessionId": popup.bridge.session,
            "slug": popup.bridge.slug,
        ]
        _ = try helper.receive(popup.bridge, "ready", identity)
        _ = try helper.receive(popup.bridge, "visualReady", identity)
        popup.detectVisualReadiness(true)
        popup.applyLayout(PopupLayout(
            contentHeight: 220,
            cornerRadius: 16,
            minimized: false,
            webControls: true
        ))
        await DecisionTests().flush()
        XCTAssertNotNil(popup.popupLayout, "Queued layout application must drain while hidden")

        popup.preparationTimedOut()
        XCTAssertTrue(sdk.active === popup, "Inactivity alone is not a readiness failure")
        XCTAssertFalse(popup.bridge.finished)
        XCTAssertFalse(popup.revealed)
        XCTAssertTrue(popup.view.isHidden)
        XCTAssertTrue(outcomes.isEmpty)

        installation.setActive(true)
        XCTAssertTrue(popup.revealed)
        XCTAssertFalse(popup.view.isHidden)
        XCTAssertTrue(sdk.active === popup)
        XCTAssertTrue(popup.webView === webView)
        XCTAssertEqual(popup.bridge.session, session)
        request.cancel()
        try await waitUntil { sdk.active == nil && outcomes == [.interrupted] }
        hosted.window.isHidden = true
    }

    func testFollowingDelayFailureReportsAndReleasesRequestCapacity() async throws {
        let hosted = try makeHostedSDK(content: UIViewController())
        let sdk = hosted.sdk
        let installation = hosted.installation
        sdk.loadPolicy = { _, _ in PresentationPolicy(
            capturePercent: 100,
            minTimeForRetake: 0,
            minTimeForRetrigger: 0,
            initialDelayMilliseconds: 1_000
        ) }
        sdk.waitForDelay = { _ in throw URLError(.timedOut) }
        var errors: [Error] = []
        _ = installation.presentSurvey(
            slug: "org/failing-delay",
            onError: { errors.append($0) }
        )
        try await waitUntil { errors.count == 1 }
        XCTAssertEqual((errors.first as? URLError)?.code, .timedOut)
        XCTAssertNil(sdk.followingLifetime, "Delay failure must release the occupied slot")

        sdk.loadPolicy = { _, _ in PresentationPolicy(
            capturePercent: 100,
            minTimeForRetake: 0,
            minTimeForRetrigger: 0
        ) }
        var outcomes: [SkyraResult] = []
        let next = installation.presentSurvey(
            slug: "org/after-error",
            onOutcome: { outcomes.append($0) }
        )
        let popup = try await waitForPopup(sdk)
        XCTAssertEqual(popup.bridge.slug, "org/after-error")
        next.cancel()
        try await waitUntil { sdk.active == nil && outcomes == [.interrupted] }
        hosted.window.isHidden = true
    }

    func testCancelledFollowingPreflightIgnoresLatePolicyAndUnblocksNextRequest() async throws {
        let hosted = try makeHostedSDK(content: UIViewController())
        let sdk = hosted.sdk
        let installation = hosted.installation
        var policyReply: CheckedContinuation<PresentationPolicy?, Error>?
        sdk.loadPolicy = { _, _ in
            try await withCheckedThrowingContinuation { policyReply = $0 }
        }
        var outcomes: [SkyraResult] = []
        let first = installation.presentSurvey(
            slug: "org/late-policy",
            onOutcome: { outcomes.append($0) }
        )
        try await waitUntil { policyReply != nil }
        XCTAssertNil(sdk.active)
        first.cancel()
        try await waitUntil { sdk.followingLifetime == nil && outcomes == [.interrupted] }
        policyReply?.resume(returning: PresentationPolicy(
            capturePercent: 100,
            minTimeForRetake: 0,
            minTimeForRetrigger: 0
        ))
        await DecisionTests().flush()
        XCTAssertNil(sdk.active, "A provider that ignores cancellation cannot attach a stale popup")

        sdk.loadPolicy = { _, _ in PresentationPolicy(
            capturePercent: 100,
            minTimeForRetake: 0,
            minTimeForRetrigger: 0
        ) }
        let next = installation.presentSurvey(
            slug: "org/next-after-cancel",
            onOutcome: { outcomes.append($0) }
        )
        let popup = try await waitForPopup(sdk)
        XCTAssertEqual(popup.bridge.slug, "org/next-after-cancel")
        next.cancel()
        try await waitUntil { sdk.active == nil && outcomes == [.interrupted, .interrupted] }
        hosted.window.isHidden = true
    }

    func testCancelledFollowingSelectionIgnoresLateProviderReplyAndReleasesSlot() async throws {
        var providerReplies: [CheckedContinuation<String?, Error>] = []
        let hosted = try makeHostedSDK(
            content: UIViewController(),
            configuration: .init(
                persistence: .ephemeral,
                organization: "org"
            )
        )
        hosted.sdk.loadSurveyList = { _, _ in
            try await withCheckedThrowingContinuation { providerReplies.append($0) }
        }
        var outcomes: [SkyraResult] = []
        let first = hosted.installation.presentSurvey(
            onOutcome: { outcomes.append($0) }
        )
        try await waitUntil { providerReplies.count == 1 }
        first.cancel()
        try await waitUntil { hosted.sdk.followingLifetime == nil && outcomes == [.interrupted] }
        providerReplies[0].resume(returning: "org/late")
        await DecisionTests().flush()
        XCTAssertNil(hosted.sdk.active)
        XCTAssertEqual(
            providerReplies.count,
            1,
            "Selection must not be re-requested after cancellation"
        )

        let next = hosted.installation.presentSurvey(
            slug: "org/next-after-selection",
            onOutcome: { outcomes.append($0) }
        )
        let popup = try await waitForPopup(hosted.sdk)
        XCTAssertEqual(popup.bridge.slug, "org/next-after-selection")
        next.cancel()
        try await waitUntil {
            hosted.sdk.active == nil && outcomes == [.interrupted, .interrupted]
        }
        hosted.window.isHidden = true
    }

    func testSelectedFirstSurveyBlockedByNativeCaptureDoesNotAskProviderAgain() async throws {
        var contexts: [String] = []
        let hosted = try makeHostedSDK(
            content: UIViewController(),
            configuration: .init(
                persistence: .ephemeral,
                organization: "org"
            )
        )
        hosted.sdk.loadSurveyList = { _, organization in
            contexts.append(organization)
            return "org/first"
        }
        var policyCalls = 0
        hosted.sdk.loadPolicy = { _, _ in
            policyCalls += 1
            return PresentationPolicy(
                capturePercent: 0,
                minTimeForRetake: nil,
                minTimeForRetrigger: nil,
                initialDelayMilliseconds: 60_000
            )
        }
        hosted.sdk.waitForDelay = { _ in XCTFail("Native capture suppression must precede delay") }
        var outcomes: [SkyraResult] = []
        _ = hosted.installation.presentSurvey(onOutcome: { outcomes.append($0) })
        try await waitUntil { outcomes.count == 1 }
        XCTAssertEqual(outcomes, [.notShown(reason: .captureNotSelected)])
        XCTAssertEqual(contexts.count, 1)
        XCTAssertEqual(contexts.first, "org")
        XCTAssertEqual(policyCalls, 1)
        XCTAssertNil(hosted.sdk.active)
        XCTAssertNil(hosted.sdk.followingLifetime)
        hosted.window.isHidden = true
    }

    func testScreenAndFollowingNoSlugShareSelectorAndInactiveCooldownDoesNotWaitOrRetry(
    ) async throws {
        var contexts: [String] = []
        let hosted = try makeHostedSDK(
            content: UIViewController(),
            active: false,
            configuration: .init(
                persistence: .ephemeral,
                organization: "org"
            )
        )
        hosted.sdk.loadSurveyList = { _, organization in
            contexts.append(organization)
            return "org/first"
        }
        let sdk = hosted.sdk
        try sdk.store.terminal(
            slug: "org/first",
            visitor: BridgeTests().visitor,
            session: "prior-rejection",
            status: .rejected
        )
        var policyCalls = 0
        sdk.loadPolicy = { _, slug in
            policyCalls += 1
            XCTAssertEqual(slug, "org/first")
            return PresentationPolicy(
                capturePercent: 100,
                minTimeForRetake: nil,
                minTimeForRetrigger: 3_600,
                initialDelayMilliseconds: 60_000
            )
        }
        sdk.waitForDelay = { _ in XCTFail("Cooldown must be evaluated before any delay") }

        let screenResult = try await sdk.presentSurvey(
            slug: nil,
            from: hosted.root.content
        )
        XCTAssertEqual(screenResult, .notShown(reason: .rejectedCooldown))
        XCTAssertEqual(contexts.count, 1)
        XCTAssertEqual(contexts[0], "org")

        var followOutcomes: [SkyraResult] = []
        _ = hosted.installation.presentSurvey(
            onOutcome: { followOutcomes.append($0) }
        )
        try await waitUntil { followOutcomes.count == 1 }
        XCTAssertEqual(followOutcomes, [.notShown(reason: .rejectedCooldown)])
        XCTAssertEqual(contexts.count, 2, "One selector call per API attempt; no fallback or retry")
        XCTAssertTrue(contexts.allSatisfy { $0 == "org" })
        XCTAssertEqual(policyCalls, 2)
        XCTAssertNil(sdk.active)
        XCTAssertNil(sdk.followingLifetime)
        hosted.window.isHidden = true
    }

    func testUIKitScreenAttachmentNilSlugUsesSameConfiguredSelectorBoundary() async throws {
        var contexts: [SkyraSurveyDecisionContext] = []
        let provider: @MainActor (SkyraSurveyDecisionContext) async throws
            -> SkyraSurveyDecision = { context in
                contexts.append(context)
                return .notShown(.unavailable)
            }
        let content = UIViewController()
        let root = SkyraRootViewController(content: content)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root
        let installation = Skyra.install(
            in: window,
            configuration: .init(
                persistence: .ephemeral,
                organization: "org",
                surveyDecision: provider
            )
        )
        let sdk = try XCTUnwrap(installation.sdk)
        var outcomes: [SkyraResult] = []
        let attachment = content.skyraSurvey(
            nil,
            onOutcome: { outcomes.append($0) }
        )
        window.makeKeyAndVisible()
        installation.setActive(true)
        defer {
            attachment.detach()
            window.isHidden = true
        }
        try await waitUntil { outcomes.count == 1 }
        XCTAssertEqual(outcomes, [.notShown(reason: .unavailable)])
        XCTAssertEqual(contexts.count, 1)
        XCTAssertEqual(contexts[0].organization, "org")
        XCTAssertNil(contexts[0].requestedSlug)
        XCTAssertNil(sdk.active)
    }

    func testPlainUIKitRootKeepsScreenInstallationButRejectsFollowingWithoutExplicitHost(
    ) async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = UIViewController()
        let installation = Skyra.install(
            in: window,
            configuration: .init(persistence: .ephemeral)
        )
        let sdk = try XCTUnwrap(installation.sdk)
        sdk.loadHostedPage = { _, _ in }
        sdk.loadPolicy = { _, _ in PresentationPolicy(
            capturePercent: 100,
            minTimeForRetake: 0,
            minTimeForRetrigger: 0
        ) }
        window.makeKeyAndVisible()
        installation.setActive(true)
        defer { window.isHidden = true }

        var errors: [Error] = []
        _ = installation.presentSurvey(
            slug: "org/no-follow-host",
            onError: { errors.append($0) }
        )
        try await waitUntil { errors.count == 1 }
        XCTAssertEqual(errors.first as? SkyraIntegrationError, .missingFollowingHost)
        XCTAssertNil(sdk.followingLifetime)
        XCTAssertNil(sdk.active)
    }

    func testFollowingWindowsKeepIndependentSlotsAndSessions() async throws {
        let first = try makeHostedSDK(content: UIViewController())
        let second = try makeHostedSDK(content: UIViewController())
        defer {
            first.window.isHidden = true
            second.window.isHidden = true
        }
        var firstOutcomes: [SkyraResult] = []
        var secondOutcomes: [SkyraResult] = []
        let firstRequest = first.installation.presentSurvey(
            slug: "org/first-window",
            onOutcome: { firstOutcomes.append($0) }
        )
        let secondRequest = second.installation.presentSurvey(
            slug: "org/second-window",
            onOutcome: { secondOutcomes.append($0) }
        )
        let firstPopup = try await waitForPopup(first.sdk)
        let secondPopup = try await waitForPopup(second.sdk)
        XCTAssertFalse(first.sdk === second.sdk)
        XCTAssertFalse(firstPopup === secondPopup)
        XCTAssertFalse(firstPopup.webView === secondPopup.webView)
        XCTAssertNotEqual(firstPopup.bridge.session, secondPopup.bridge.session)
        XCTAssertTrue(firstPopup.view.window === first.window)
        XCTAssertTrue(secondPopup.view.window === second.window)

        firstRequest.cancel()
        try await waitUntil { first.sdk.active == nil && firstOutcomes == [.interrupted] }
        XCTAssertTrue(
            second.sdk.active === secondPopup,
            "One window's cancellation must not affect another"
        )
        XCTAssertTrue(secondOutcomes.isEmpty)
        secondRequest.cancel()
        try await waitUntil { second.sdk.active == nil && secondOutcomes == [.interrupted] }
    }

    func testDestroyingWindowInvalidatesFollowingRequestWhileOwnersRemainRetained() async throws {
        let content = UIViewController()
        let root = SkyraRootViewController(content: content)
        var window: UIWindow? = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window?.rootViewController = root
        let installation = Skyra.install(
            in: window!,
            configuration: .init(persistence: .ephemeral)
        )
        let sdk = try XCTUnwrap(installation.sdk)
        sdk.loadHostedPage = { _, _ in }
        sdk.loadPolicy = { _, _ in PresentationPolicy(
            capturePercent: 100,
            minTimeForRetake: 0,
            minTimeForRetrigger: 0
        ) }
        window?.makeKeyAndVisible()
        installation.setActive(true)
        var outcomes: [SkyraResult] = []
        _ = installation.presentSurvey(slug: "org/window-end", onOutcome: { outcomes.append($0) })
        let popup = try await waitForPopup(sdk)
        weak var releasedWindow = window
        XCTAssertTrue(popup.view.window === window)

        window?.isHidden = true
        window = nil
        try await waitUntil { outcomes == [.interrupted] && sdk.followingLifetime == nil }
        XCTAssertNil(
            releasedWindow,
            "The test retains installation and root, not the destroyed window"
        )
        XCTAssertTrue(installation.sdk === sdk)
        XCTAssertTrue(root.content === content)
        XCTAssertNil(sdk.active)
    }

    func testFollowingHostDisconnectFiltersOtherSceneAndEndsOnlyItsOwnScene() async throws {
        guard
            let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first
        else {
            throw XCTSkip("UIKit did not attach this test window to a UIWindowScene")
        }

        let actualWindow = UIWindow(windowScene: scene)
        actualWindow.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let hosted = try makeHostedSDK(content: UIViewController(), window: actualWindow)
        defer { hosted.window.isHidden = true }
        var outcomes: [SkyraResult] = []
        let request = hosted.installation.presentSurvey(
            slug: "org/disconnect",
            onOutcome: { outcomes.append($0) }
        )
        let popup = try await waitForPopup(hosted.sdk)
        let unrelatedScene = NSObject()
        NotificationCenter.default.post(
            name: UIScene.didDisconnectNotification,
            object: unrelatedScene
        )
        await DecisionTests().flush()
        XCTAssertTrue(hosted.sdk.active === popup)
        XCTAssertTrue(outcomes.isEmpty, "An unrelated scene disconnect must not cancel this host")

        NotificationCenter.default.post(
            name: UIScene.didDisconnectNotification,
            object: scene
        )
        try await waitUntil { outcomes == [.interrupted] && hosted.sdk.followingLifetime == nil }
        XCTAssertNil(hosted.sdk.active)
        request.cancel()
        XCTAssertEqual(
            outcomes,
            [.interrupted],
            "Disconnect and stale handle cancellation finish once"
        )
    }

    func testFollowingHostSelectorNotificationsAreScopedToInjectedSceneToken() async throws {
        let hosted = try makeHostedSDK(content: UIViewController())
        defer { hosted.window.isHidden = true }
        let center = NotificationCenter()
        let ownScope = NSObject()
        let otherScope = NSObject()
        hosted.sdk.followingHost?.invalidate()
        let scopedHost = FollowingHost(
            sdk: hosted.sdk,
            controller: hosted.root,
            window: hosted.window,
            scope: ownScope,
            center: center
        )
        hosted.sdk.followingHost = scopedHost
        hosted.sdk.followingHostExpected = true

        center.post(name: UIScene.willDeactivateNotification, object: ownScope)
        XCTAssertFalse(
            hosted.sdk.sceneActive,
            "The matching scene event updates the gate synchronously"
        )
        center.post(name: UIScene.didActivateNotification, object: otherScope)
        XCTAssertFalse(hosted.sdk.sceneActive, "A different scene's activation is ignored")
        center.post(name: UIScene.didActivateNotification, object: ownScope)
        XCTAssertTrue(hosted.sdk.sceneActive)

        var outcomes: [SkyraResult] = []
        let request = hosted.installation.presentSurvey(
            slug: "org/scoped-scene",
            onOutcome: { outcomes.append($0) }
        )
        let popup = try await waitForPopup(hosted.sdk)
        center.post(name: UIScene.didDisconnectNotification, object: otherScope)
        XCTAssertTrue(scopedHost.isValid, "An unrelated disconnect cannot invalidate this host")
        XCTAssertTrue(hosted.sdk.active === popup)
        center.post(name: UIScene.willDeactivateNotification, object: ownScope)
        XCTAssertFalse(hosted.sdk.sceneActive)
        XCTAssertTrue(hosted.sdk.active === popup, "Inactivity suspends rather than terminates")
        center.post(name: UIScene.didActivateNotification, object: ownScope)
        XCTAssertTrue(hosted.sdk.sceneActive)
        XCTAssertTrue(hosted.sdk.active === popup)

        center.post(name: UIScene.didDisconnectNotification, object: ownScope)
        XCTAssertFalse(scopedHost.isValid)
        try await waitUntil { outcomes == [.interrupted] && hosted.sdk.followingLifetime == nil }
        XCTAssertNil(hosted.sdk.active)
        request.cancel()
        XCTAssertEqual(outcomes, [.interrupted])
    }

    func testAcceptedFollowingSurveyCompletesExactlyOnceWhenHiddenThenCancelledOrDismissed(
    ) async throws {
        for closeByDismiss in [false, true] {
            let navigation = UINavigationController(rootViewController: UIViewController())
            let hosted = try makeHostedSDK(content: navigation)
            defer { hosted.window.isHidden = true }
            var outcomes: [SkyraResult] = []
            let request = hosted.installation.presentSurvey(
                slug: "org/accepted",
                onOutcome: { outcomes.append($0) }
            )
            let popup = try await waitForPopup(hosted.sdk)
            let helper = BridgeTests()
            let readyIdentity: [String: Any] = [
                "visitorId": popup.bridge.visitor,
                "sessionId": popup.bridge.session,
                "slug": popup.bridge.slug,
            ]
            let ready = try helper.receive(popup.bridge, "ready", readyIdentity)
            if case .ready = ready {}
            else {
                XCTFail("Expected ready before reading survey identity")
            }
            let surveyID = try XCTUnwrap(popup.bridge.survey)
            let saved = try StorageTests().state(
                slug: "org/accepted",
                status: "Completed",
                updated: Clock.nowMilliseconds()
            )
            var stateObject = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any]
            )
            stateObject["visitorId"] = popup.bridge.visitor
            stateObject["sessionId"] = popup.bridge.session
            stateObject["surveyId"] = surveyID
            let acceptedAt = Clock.nowMilliseconds()
            let stateEvent = popup.bridge.receive(
                try helper.message("state", overrides: [
                    "slug": popup.bridge.slug,
                    "visitorId": popup.bridge.visitor,
                    "sessionId": popup.bridge.session,
                    "surveyId": surveyID,
                    "state": stateObject,
                ]),
                mainFrame: true,
                source: popup.bridge.origin,
                now: acceptedAt
            )
            if case .state = stateEvent {}
            else {
                XCTFail("Expected accepted state event, got \(stateEvent)")
            }
            XCTAssertTrue(popup.bridge.accepted)

            let cover = UIViewController()
            cover.modalPresentationStyle = .fullScreen
            navigation.present(cover, animated: false)
            hosted.installation.setActive(false)
            if closeByDismiss {
                hosted.installation.dismissSurvey()
            } else {
                request.cancel()
            }
            try await waitUntil { hosted.sdk.active == nil && outcomes.count == 1 }
            XCTAssertEqual(outcomes, [.completed])
            XCTAssertEqual(try hosted.sdk.store.history(slug: "org/accepted")?.status, .completed)

            // Repeating the other native close path after teardown cannot send a second outcome.
            if closeByDismiss {
                request.cancel()
            } else {
                hosted.installation.dismissSurvey()
            }
            await DecisionTests().flush()
            XCTAssertEqual(outcomes, [.completed])
        }
    }

    func testDeliberateHiddenDismissalRejectsAndClearsSavedCaptureProgress() async throws {
        let navigation = UINavigationController(rootViewController: UIViewController())
        let hosted = try makeHostedSDK(content: navigation)
        let sdk = hosted.sdk
        let installation = hosted.installation
        let saved = try StorageTests().state(
            slug: "org/hidden-reject",
            status: "Capture",
            updated: Clock.nowMilliseconds()
        )
        try sdk.store.save(saved)
        sdk.waitForDelay = { _ in XCTFail("A saved Capture must not wait for a fresh delay") }
        var outcomes: [SkyraResult] = []
        let request = installation.presentSurvey(
            slug: "org/hidden-reject",
            onOutcome: { outcomes.append($0) }
        )
        let popup = try await waitForPopup(sdk)
        XCTAssertEqual(popup.bridge.session, saved.sessionId)
        let cover = UIViewController()
        cover.modalPresentationStyle = .fullScreen
        navigation.present(cover, animated: false)
        installation.setActive(false)
        installation.dismissSurvey()
        try await waitUntil { sdk.active == nil && outcomes.count == 1 }
        XCTAssertEqual(outcomes, [.rejected])
        XCTAssertEqual(try sdk.store.history(slug: "org/hidden-reject")?.status, .rejected)
        let record = try sdk.store.transaction { _ in }.surveys["org/hidden-reject"]
        XCTAssertNil(
            record?.active,
            "Explicit rejection while hidden must clear resumable progress"
        )
        request.cancel()
        await DecisionTests().flush()
        XCTAssertEqual(outcomes, [.rejected])
        hosted.window.isHidden = true
    }

    private func waitUntil(
        timeout: TimeInterval = 10,
        message: String = "Following request lifecycle condition timed out",
        _ condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(condition(), message)
    }
}
#endif
