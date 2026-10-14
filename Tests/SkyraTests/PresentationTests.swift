// Exercises real UIKit popup ownership, visibility, cancellation, and cleanup on iOS Simulator.
// Policy and page messages are injected so these tests do not need a running hosted survey service.
#if canImport(UIKit)
import XCTest
import UIKit
import WebKit
import SwiftUI
@testable import Skyra

/// XCTest owns these main-actor scenarios because UIKit presentation and its callbacks run on that actor.
@MainActor
final class PresentationTests: XCTestCase {
    private struct ScreenPriorityHost {
        let sdk: Skyra
        let installation: SkyraInstallation
        let root: SkyraRootViewController
        let navigation: UINavigationController
        let window: UIWindow
        let probe: ScreenPriorityProbe
    }

    private final class ScreenPriorityProbe {
        var pageLoads: [String] = []
        var policyLookups: [String] = []
        var decisions: [String?] = []
    }

    private func makeScreenPriorityHost() async throws -> ScreenPriorityHost {
        let navigation = UINavigationController(rootViewController: UIViewController())
        let root = SkyraRootViewController(content: navigation)
        let window = try sceneWindow()
        let probe = ScreenPriorityProbe()
        window.rootViewController = root
        let configuration = SkyraConfiguration(
            persistence: .ephemeral,
            organization: "org",
            surveyDecision: { context in
                probe.decisions.append(context.requestedSlug)
                guard let slug = context.requestedSlug else {
                    return .notShown(.unavailable)
                }

                return .present(slug: slug)
            }
        )
        let installation = Skyra.install(in: window, configuration: configuration)
        let sdk = try XCTUnwrap(installation.sdk)
        sdk.loadHostedPage = { _, request in
            probe.pageLoads.append(request.url?.query ?? "")
        }
        sdk.loadPolicy = { _, slug in
            probe.policyLookups.append(slug)
            return PresentationPolicy(
                capturePercent: 100,
                minTimeForRetake: 0,
                minTimeForRetrigger: 0
            )
        }
        window.makeKeyAndVisible()
        installation.setActive(true)
        try await waitForPriorityCondition("following host becomes available") {
            sdk.followingHost?.isValid == true && sdk.followingHost?.isAvailable == true
        }
        return ScreenPriorityHost(
            sdk: sdk,
            installation: installation,
            root: root,
            navigation: navigation,
            window: window,
            probe: probe
        )
    }

    private func waitForPriorityCondition(
        _ description: String,
        timeout: TimeInterval = 5,
        condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertTrue(condition(), "Timed out waiting for \(description)")
    }

    /// Drive validated page readiness through the real popup bridge and reveal path.
    private func revealPriorityPopup(_ popup: SurveyController) async throws {
        let bridgeTests = BridgeTests()
        let identity: [String: Any] = [
            "visitorId": popup.bridge.visitor,
            "sessionId": popup.bridge.session,
            "slug": popup.bridge.slug,
        ]
        let ready = try bridgeTests.receive(popup.bridge, "ready", identity)
        guard case .ready = ready else {
            return XCTFail("Expected a valid ready event, got \(ready)")
        }

        let visualReady = try bridgeTests.receive(popup.bridge, "visualReady", identity)
        guard case .visualReady = visualReady else {
            return XCTFail("Expected a valid visual-ready event, got \(visualReady)")
        }

        popup.detectVisualReadiness(true)
        popup.applyLayout(PopupLayout(
            contentHeight: 220,
            cornerRadius: 16,
            minimized: false,
            webControls: true
        ))
        await DecisionTests().flush()
        XCTAssertTrue(popup.revealed, "The popup should reveal through its normal readiness path")
    }

    private func pushPriorityScreen(
        slug: String,
        onOutcome: @escaping (SkyraResult) -> Void,
        in host: ScreenPriorityHost
    ) -> (UIViewController, SkyraSurveyAttachment) {
        let screen = UIViewController()
        let attachment = screen.skyraSurvey(slug, onOutcome: onOutcome)
        host.navigation.pushViewController(screen, animated: false)
        return (screen, attachment)
    }

    private func completePriorityPopup(_ popup: SurveyController) throws {
        let helper = BridgeTests()
        let surveyID = try XCTUnwrap(popup.bridge.survey)
        let saved = try StorageTests().state(
            slug: popup.bridge.slug,
            status: "Completed",
            updated: Clock.nowMilliseconds()
        )
        var state = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any]
        )
        state["visitorId"] = popup.bridge.visitor
        state["sessionId"] = popup.bridge.session
        state["surveyId"] = surveyID
        let event = popup.bridge.receive(
            try helper.message("state", overrides: [
                "slug": popup.bridge.slug,
                "visitorId": popup.bridge.visitor,
                "sessionId": popup.bridge.session,
                "surveyId": surveyID,
                "state": state,
            ]),
            mainFrame: true,
            source: popup.bridge.origin,
            now: Clock.nowMilliseconds()
        )
        guard case .state = event else {
            return XCTFail("Expected an accepted state event, got \(event)")
        }

        XCTAssertTrue(popup.bridge.accepted)
    }

    func testSameSlugScreenVisitKeepsFollowingControllerSessionAndWebView() async throws {
        let host = try await makeScreenPriorityHost()
        defer { host.window.isHidden = true }
        var followingOutcomes: [SkyraResult] = []
        let following = host.installation.presentSurvey(
            slug: "org/same",
            onOutcome: { followingOutcomes.append($0) }
        )
        let popup = try await attachedPopup(host.sdk)
        try await revealPriorityPopup(popup)
        let webView = popup.webView
        let session = popup.bridge.session
        let decisionsBeforeScreenEntry = host.probe.decisions.count
        let policyLookupsBeforeScreenEntry = host.probe.policyLookups.count

        var screenOutcomes: [SkyraResult] = []
        _ = pushPriorityScreen(slug: "org/same", onOutcome: { screenOutcomes.append($0) }, in: host)
        try await waitForPriorityCondition("same-slug screen visit to alias following A") {
            host.sdk.screenPriorityVisit != nil && host.sdk.screenPriorityAliasesFollowing &&
                host.sdk.screenCandidateVisit == nil && host.sdk.screenCandidateController == nil &&
                host.sdk.pendingPresentation == nil
        }

        XCTAssertTrue(host.sdk.active === popup)
        XCTAssertTrue(popup.webView === webView)
        XCTAssertEqual(popup.bridge.session, session)
        XCTAssertEqual(
            host.probe.pageLoads.count,
            1,
            "A same-slug visit must not reload the hosted page"
        )
        XCTAssertEqual(host.probe.decisions.count, decisionsBeforeScreenEntry)
        XCTAssertEqual(host.probe.policyLookups.count, policyLookupsBeforeScreenEntry)
        XCTAssertTrue(followingOutcomes.isEmpty)

        host.navigation.popViewController(animated: false)
        try await waitForPriorityCondition("same-slug screen lease to release") {
            host.sdk.screenPriorityVisit == nil && host.sdk.active === popup
        }
        XCTAssertTrue(host.sdk.active === popup)
        XCTAssertTrue(followingOutcomes.isEmpty)
        following.cancel()
    }

    func testCancellingParkedFollowingRequestLeavesScreenPopupAndLeaseAlone() async throws {
        let host = try await makeScreenPriorityHost()
        defer { host.window.isHidden = true }
        var followingOutcomes: [SkyraResult] = []
        let following = host.installation.presentSurvey(
            slug: "org/a",
            onOutcome: { followingOutcomes.append($0) }
        )
        let a = try await attachedPopup(host.sdk)
        try await revealPriorityPopup(a)

        var screenOutcomes: [SkyraResult] = []
        _ = pushPriorityScreen(slug: "org/b", onOutcome: { screenOutcomes.append($0) }, in: host)
        try await waitForPriorityCondition("screen B candidate") {
            host.sdk.screenCandidateController?.bridge.slug == "org/b"
        }
        let b = try XCTUnwrap(host.sdk.screenCandidateController)
        try await revealPriorityPopup(b)
        try await waitForPriorityCondition("screen B to acquire priority") {
            host.sdk.active === b && host.sdk.parkedFollowing === a &&
                host.sdk.screenPriorityVisit !=
                nil
        }

        var duplicateErrors: [Error] = []
        _ = host.installation.presentSurvey(
            slug: "org/duplicate",
            onError: { duplicateErrors.append($0) }
        )
        XCTAssertEqual(duplicateErrors.count, 1)
        XCTAssertEqual(duplicateErrors.first as? SkyraError, .alreadyPresenting)

        following.cancel()
        try await waitForPriorityCondition("parked A cancellation") {
            followingOutcomes == [.interrupted]
        }
        XCTAssertTrue(host.sdk.active === b, "Cancelling parked A must not affect B")
        XCTAssertNil(host.sdk.parkedFollowing)
        XCTAssertTrue(screenOutcomes.isEmpty)

        host.navigation.popViewController(animated: false)
        try await waitForPriorityCondition("B screen departure") {
            screenOutcomes == [.interrupted] && host.sdk.active == nil
        }
        XCTAssertEqual(followingOutcomes, [.interrupted])
        XCTAssertEqual(screenOutcomes, [.interrupted])
    }

    func testSceneActivitySuspendsAndResumesPriorityPopupBeforeScreenLeaves() async throws {
        let host = try await makeScreenPriorityHost()
        defer { host.window.isHidden = true }
        let center = NotificationCenter()
        let scope = NSObject()
        host.sdk.followingHost?.invalidate()
        let scopedHost = FollowingHost(
            sdk: host.sdk,
            controller: host.root,
            window: host.window,
            scope: scope,
            center: center
        )
        host.sdk.followingHost = scopedHost
        host.sdk.followingHostExpected = true

        var followingOutcomes: [SkyraResult] = []
        let following = host.installation.presentSurvey(
            slug: "org/a",
            onOutcome: { followingOutcomes.append($0) }
        )
        let a = try await attachedPopup(host.sdk)
        try await revealPriorityPopup(a)
        var screenOutcomes: [SkyraResult] = []
        _ = pushPriorityScreen(slug: "org/b", onOutcome: { screenOutcomes.append($0) }, in: host)
        try await waitForPriorityCondition("screen B candidate") {
            host.sdk.screenCandidateController?.bridge.slug == "org/b"
        }
        let b = try XCTUnwrap(host.sdk.screenCandidateController)
        try await revealPriorityPopup(b)
        try await waitForPriorityCondition("screen B to acquire priority") {
            host.sdk.active === b && host.sdk.parkedFollowing === a
        }

        center.post(name: UIScene.willDeactivateNotification, object: scope)
        XCTAssertTrue(b.view.isHidden)
        XCTAssertTrue(a.view.isHidden)
        XCTAssertTrue(followingOutcomes.isEmpty)
        XCTAssertTrue(screenOutcomes.isEmpty)

        center.post(name: UIScene.didActivateNotification, object: scope)
        try await waitForPriorityCondition("screen B to resume") {
            !b.view.isHidden && host.sdk.active === b && host.sdk.parkedFollowing === a
        }
        XCTAssertTrue(followingOutcomes.isEmpty)

        host.navigation.popViewController(animated: false)
        try await waitForPriorityCondition("screen departure to resume A") {
            screenOutcomes == [.interrupted] && host.sdk.active === a && host.sdk.parkedFollowing ==
                nil
        }
        XCTAssertTrue(a.view.window === host.root.view.window)
        following.cancel()
        try await waitForPriorityCondition("A cancellation after resume") {
            followingOutcomes == [.interrupted] && host.sdk.active == nil
        }
        scopedHost.invalidate()
    }

    func testFollowingHostDisconnectFinishesParkedAndPriorityPopupsOnce() async throws {
        let host = try await makeScreenPriorityHost()
        defer { host.window.isHidden = true }
        let center = NotificationCenter()
        let scope = NSObject()
        host.sdk.followingHost?.invalidate()
        let scopedHost = FollowingHost(
            sdk: host.sdk,
            controller: host.root,
            window: host.window,
            scope: scope,
            center: center
        )
        host.sdk.followingHost = scopedHost
        host.sdk.followingHostExpected = true

        var followingOutcomes: [SkyraResult] = []
        let following = host.installation.presentSurvey(
            slug: "org/a",
            onOutcome: { followingOutcomes.append($0) }
        )
        let a = try await attachedPopup(host.sdk)
        try await revealPriorityPopup(a)
        var screenOutcomes: [SkyraResult] = []
        _ = pushPriorityScreen(slug: "org/b", onOutcome: { screenOutcomes.append($0) }, in: host)
        try await waitForPriorityCondition("screen B candidate") {
            host.sdk.screenCandidateController?.bridge.slug == "org/b"
        }
        let b = try XCTUnwrap(host.sdk.screenCandidateController)
        try await revealPriorityPopup(b)
        try await waitForPriorityCondition("screen B to acquire priority") {
            host.sdk.active === b && host.sdk.parkedFollowing === a
        }

        center.post(name: UIScene.didDisconnectNotification, object: scope)
        try await waitForPriorityCondition("both visits to terminate on host disconnect") {
            followingOutcomes.count == 1 && screenOutcomes.count == 1 && host.sdk.active == nil
        }
        XCTAssertFalse(scopedHost.isValid)
        XCTAssertEqual(followingOutcomes, [.interrupted])
        XCTAssertEqual(screenOutcomes, [.interrupted])
        XCTAssertNil(host.sdk.parkedFollowing)

        host.navigation.popViewController(animated: false)
        following.cancel()
        await DecisionTests().flush()
        XCTAssertEqual(followingOutcomes, [.interrupted])
        XCTAssertEqual(screenOutcomes, [.interrupted])
    }

    func testAcceptedParkedFollowingPopupCompletesOnceAndDoesNotReturnAfterScreenLeaves(
    ) async throws {
        let host = try await makeScreenPriorityHost()
        defer { host.window.isHidden = true }
        var followingOutcomes: [SkyraResult] = []
        let following = host.installation.presentSurvey(
            slug: "org/a",
            onOutcome: { followingOutcomes.append($0) }
        )
        let a = try await attachedPopup(host.sdk)
        try await revealPriorityPopup(a)
        var screenOutcomes: [SkyraResult] = []
        _ = pushPriorityScreen(slug: "org/b", onOutcome: { screenOutcomes.append($0) }, in: host)
        try await waitForPriorityCondition("screen B candidate") {
            host.sdk.screenCandidateController?.bridge.slug == "org/b"
        }
        let b = try XCTUnwrap(host.sdk.screenCandidateController)
        try await revealPriorityPopup(b)
        try await waitForPriorityCondition("screen B to acquire priority") {
            host.sdk.active === b && host.sdk.parkedFollowing === a
        }

        try completePriorityPopup(a)
        following.cancel()
        try await waitForPriorityCondition("accepted parked A to finish") {
            followingOutcomes == [.completed]
        }
        XCTAssertTrue(host.sdk.active === b, "A's accepted terminal callback must not cancel B")
        XCTAssertTrue(screenOutcomes.isEmpty)

        host.navigation.popViewController(animated: false)
        try await waitForPriorityCondition("B departure after A completion") {
            screenOutcomes == [.interrupted] && host.sdk.active == nil
        }
        await DecisionTests().flush()
        XCTAssertEqual(followingOutcomes, [.completed])
        XCTAssertEqual(screenOutcomes, [.interrupted])
        XCTAssertNil(host.sdk.parkedFollowing, "Completed A must not resurrect after B leaves")
    }

    private final class AppearanceProbeViewController: UIViewController {
        var onNextAppearance: (() -> Void)?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            let callback = onNextAppearance
            onNextAppearance = nil
            callback?()
        }
    }

    private func appearanceExpectation(
        for home: AppearanceProbeViewController,
        description: String
    ) -> XCTestExpectation {
        let appeared = expectation(description: description)
        home.onNextAppearance = { appeared.fulfill() }
        return appeared
    }

    private func awaitVisibleHome(
        _ appeared: XCTestExpectation,
        home: AppearanceProbeViewController,
        navigation: UINavigationController,
        window: UIWindow,
        milestone: String
    ) async -> Bool {
        await fulfillment(of: [appeared], timeout: 5)
        let attached = home.viewIfLoaded?.window === window
        let visible = navigation.visibleViewController === home
        let notDismissed = !home.isBeingDismissed
        let noPresentedController = home.presentedViewController == nil
        XCTAssertTrue(attached, "\(milestone): home must be attached to the test window")
        XCTAssertTrue(visible, "\(milestone): navigation must show home")
        XCTAssertTrue(notDismissed, "\(milestone): home must not be dismissing")
        XCTAssertTrue(noPresentedController, "\(milestone): home must have no presented controller")
        return attached && visible && notDismissed && noPresentedController
    }

    /// A screen may request before the root anchor registers. Reserve the slot but do no delivery or storage work.
    func testRequestWaitsForPresenterAndRejectsConcurrentRequests() async throws {
        let sdk = try makeSDK()
        var lookups = 0
        sdk.loadPolicy = { _, _ in
            lookups += 1
            return nil
        }
        let request = Task { try await sdk.presentSurvey(slug: "org/survey") }
        defer { request.cancel() }
        await DecisionTests().flush()
        XCTAssertNotNil(sdk.pendingPresentation?.presenterContinuation)
        XCTAssertEqual(lookups, 0)
        XCTAssertNil(try sdk.store.storage.update(key: sdk.store.key) { $0 })
        do {
            _ = try await sdk.presentSurvey(slug: "org/other")
            XCTFail("Readiness must reserve the slot")
        } catch {
            XCTAssertEqual(error as? SkyraError, .alreadyPresenting)
        }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        sdk.setPresenter(host)
        let result = try await request.value
        XCTAssertEqual(result, .notShown(reason: .unavailable))
        XCTAssertEqual(lookups, 1)
        XCTAssertNil(sdk.pendingPresentation)
    }

    /// Cancellation wins over a late anchor and leaves no history or occupied slot, including on re-entry.
    func testPresenterReadinessCancellationAndLateRegistration() async throws {
        for action in ["task", "dismiss", "scene", "detach"] {
            let sdk = try makeSDK()
            var lookups = 0
            sdk.loadPolicy = { _, _ in
                lookups += 1
                return nil
            }
            let request = Task { try await sdk.presentSurvey(slug: "org/survey") }
            await DecisionTests().flush()
            XCTAssertNotNil(sdk.pendingPresentation?.presenterContinuation)
            switch action {
            case "task":
                request.cancel()
            case "dismiss":
                sdk.dismissSurvey()
            case "scene":
                sdk.setSceneActive(false)
            default:
                sdk.setPresenter(nil)
            }
            do {
                _ = try await request.value
                XCTFail("Readiness must cancel")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            let host = UIViewController()
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            sdk.setSceneActive(true)
            sdk.setPresenter(host)
            await DecisionTests().flush()
            XCTAssertEqual(lookups, 0)
            XCTAssertNil(sdk.active)
            XCTAssertNil(sdk.pendingPresentation)
            XCTAssertNil(try sdk.store.storage.update(key: sdk.store.key) { $0 })
            let result = try await sdk.presentSurvey(slug: "org/survey")
            XCTAssertEqual(result, .notShown(reason: .unavailable))
            XCTAssertEqual(lookups, 1)
        }
    }

    /// Exercise the guide's actual SwiftUI composition on first launch, with no button or timing workaround.
    func testSwiftUIScreenTaskAtLaunchUsesRootPresenter() async throws {
        let sdk = try makeSDK()
        sdk.loadPolicy = { _, _ in nil }
        let finished = expectation(description: "screen task completed")
        let screen = Text("Home").task {
            do {
                let result = try await sdk.presentSurvey(slug: "org/survey")
                XCTAssertEqual(result, .notShown(reason: .unavailable))
            } catch {
                XCTFail("Launch request failed: \(error)")
            }
            finished.fulfill()
        }
        let root = NavigationView { screen }.background(SkyraPresenter(sdk))
        let window = try sceneWindow()
        window.rootViewController = UIHostingController(rootView: root)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertNotNil(sdk.presenter)
        XCTAssertNil(sdk.pendingPresentation)
    }

    /// Give each scenario an ephemeral SDK with an immediate permissive policy instead of a network lookup.
    func makeSDK(
        configuration: SkyraConfiguration = .init(persistence: .ephemeral),
        storage: SkyraStorage? = nil
    ) throws -> Skyra {
        let sdk = try Skyra(configuration: configuration, storage: storage)
        sdk.loadHostedPage = { _, _ in }
        sdk.loadPolicy = { _, _ in PresentationPolicy(
            capturePercent: 100,
            minTimeForRetake: 60,
            minTimeForRetrigger: 60
        ) }
        return sdk
    }

    func sceneWindow() throws -> UIWindow {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive },
            "Presentation lifecycle test requires a foreground-active UIWindowScene"
        )
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        return window
    }

    /// Wait for the observable attachment, rather than assuming a fixed number of executor turns.
    func attachedPopup(_ sdk: Skyra) async throws -> SurveyController {
        let deadline = Date().addingTimeInterval(5)
        while sdk.active == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        return try XCTUnwrap(sdk.active)
    }

    /// Delivered milliseconds delay session allocation and reserve the slot until the wait completes.
    func testInitialDelayPrecedesPopupAndStorage() async throws {
        let sdk = try makeSDK()
        sdk.loadPolicy = { _, _ in PresentationPolicy(
            capturePercent: 100,
            minTimeForRetake: 60,
            minTimeForRetrigger: 60,
            initialDelayMilliseconds: 5000
        ) }
        let waiting = expectation(description: "waiting for delivered delay")
        var release: CheckedContinuation<Void, Error>?
        sdk.waitForDelay = { nanoseconds in
            XCTAssertEqual(nanoseconds, 5_000_000_000)
            try await withCheckedThrowingContinuation {
                release = $0
                waiting.fulfill()
            }
        }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let home = UIViewController()
        window.rootViewController = home
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let request = Task { try await sdk.presentSurvey(slug: "org/survey", from: home) }
        defer { request.cancel() }
        await fulfillment(of: [waiting], timeout: 2)
        XCTAssertNil(sdk.active)
        XCTAssertNotNil(sdk.pendingPresentation)
        XCTAssertNil(try sdk.store.storage.update(key: sdk.store.key) { $0 })
        do {
            _ = try await sdk.presentSurvey(slug: "org/other", from: home)
            XCTFail("Delay must reserve the presentation slot")
        } catch {
            XCTAssertEqual(error as? SkyraError, .alreadyPresenting)
        }
        release?.resume()
        let popup = try await attachedPopup(sdk)
        popup.interrupt()
        let result = try await request.value
        XCTAssertEqual(result, .interrupted)
    }

    /// Leaving during the timer must return promptly without rejection, even when a timer replies late.
    func testInitialDelayCancellationAndLateTimer() async throws {
        for action in ["navigation", "cancel", "dismiss", "presenter", "scene"] {
            let sdk = try makeSDK()
            sdk.loadPolicy = { _, _ in PresentationPolicy(
                capturePercent: 100,
                minTimeForRetake: nil,
                minTimeForRetrigger: nil,
                initialDelayMilliseconds: 5000
            ) }
            let waiting = expectation(description: "delay started: \(action)")
            var release: CheckedContinuation<Void, Error>?
            sdk.waitForDelay = { _ in
                try await withCheckedThrowingContinuation {
                    release = $0
                    waiting.fulfill()
                }
            }
            let home = AppearanceProbeViewController()
            let navigation = UINavigationController(rootViewController: home)
            let window = try sceneWindow()
            window.rootViewController = navigation
            let appeared = appearanceExpectation(
                for: home,
                description: "Home appearance before \(action) presentation request"
            )
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            guard
                await awaitVisibleHome(
                    appeared,
                    home: home,
                    navigation: navigation,
                    window: window,
                    milestone: "Initial \(action) request"
                )
            else {
                return
            }

            sdk.setPresenter(home)
            let request = Task { try await sdk.presentSurvey(slug: "org/survey") }
            await fulfillment(of: [waiting], timeout: 2)
            switch action {
            case "navigation":
                navigation.pushViewController(UIViewController(), animated: false)
            case "cancel":
                request.cancel()
            case "dismiss":
                sdk.dismissSurvey()
            case "presenter":
                sdk.setPresenter(nil)
            default:
                sdk.setSceneActive(false)
            }
            do {
                _ = try await request.value
                XCTFail("Pending delay should be cancelled")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            release?.resume()
            await DecisionTests().flush()
            XCTAssertNil(sdk.active)
            XCTAssertNil(sdk.pendingPresentation)
            XCTAssertTrue(home.children.isEmpty)
            XCTAssertNil(try sdk.store.storage.update(key: sdk.store.key) { $0 })
        }
    }

    /// Restoring Capture skips the timer; a suppressed request also never waits or creates a popup.
    func testInitialDelaySkippedForCaptureAndSuppression() async throws {
        for resume in [true, false] {
            let sdk = try makeSDK()
            sdk.loadPolicy = { _, _ in PresentationPolicy(
                capturePercent: 0,
                minTimeForRetake: nil,
                minTimeForRetrigger: nil,
                initialDelayMilliseconds: 5000
            ) }
            sdk.waitForDelay = { _ in XCTFail("No delay for restoration or suppression") }
            if resume {
                try sdk.store.save(StorageTests().state(updated: Clock.nowMilliseconds()))
            }
            let home = UIViewController()
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.rootViewController = home
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            let request = Task { try await sdk.presentSurvey(slug: "org/survey", from: home) }
            await DecisionTests().flush()
            if resume {
                let popup = try XCTUnwrap(sdk.active)
                popup.interrupt()
            }
            let result = try await request.value
            XCTAssertEqual(result, resume ? .interrupted : .notShown(reason: .captureNotSelected))
        }
    }

    /// Pushing a screen interrupts Home without rejection; returning can request its saved session again.
    func testNavigationPreservesSessionAndRequiresAnotherRequest() async throws {
        let sdk = try makeSDK()
        try sdk.store.save(StorageTests().state(updated: Clock.nowMilliseconds()))
        let home = AppearanceProbeViewController()
        let navigation = UINavigationController(rootViewController: home)
        let window = try sceneWindow()
        window.rootViewController = navigation
        let appeared = appearanceExpectation(
            for: home,
            description: "Home appearance before navigation request"
        )
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        guard
            await awaitVisibleHome(
                appeared,
                home: home,
                navigation: navigation,
                window: window,
                milestone: "Initial navigation request"
            )
        else {
            return
        }

        let task = Task { try await sdk.presentSurvey(slug: "org/survey", from: home) }
        let controller = try await attachedPopup(sdk)
        let session = controller.bridge.session
        navigation.pushViewController(UIViewController(), animated: false)
        let result = try await task.value
        XCTAssertEqual(result, .interrupted)
        XCTAssertNil(sdk.active)
        XCTAssertEqual(try sdk.store.history(slug: "org/survey")?.status, .capture)
        let returned = appearanceExpectation(
            for: home,
            description: "Home appearance after navigation pop before explicit re-request"
        )
        navigation.popViewController(animated: false)
        guard
            await awaitVisibleHome(
                returned,
                home: home,
                navigation: navigation,
                window: window,
                milestone: "Navigation reentry"
            )
        else {
            return
        }

        XCTAssertNil(sdk.active)
        let next = Task { try await sdk.presentSurvey(slug: "org/survey", from: home) }
        let resumed = try await attachedPopup(sdk)
        XCTAssertEqual(resumed.bridge.session, session)
        next.cancel()
        let nextResult = try await next.value
        XCTAssertEqual(nextResult, .interrupted)
    }

    /// Pending policy lookups reserve the slot; cancellation and host changes must make late replies harmless.
    func testPendingOwnershipCancellationAndIgnoredLateMetadata() async throws {
        for action in ["dismiss", "cancel", "presenter", "scene", "navigation"] {
            let sdk = try makeSDK()
            var reply: CheckedContinuation<PresentationPolicy?, Error>?
            let policyStarted = expectation(description: "policy lookup started: \(action)")
            sdk.loadPolicy = { _, _ in
                try await withCheckedThrowingContinuation {
                    reply = $0
                    policyStarted.fulfill()
                }
            }
            let window = try sceneWindow()
            let host = AppearanceProbeViewController()
            let navigation = UINavigationController(rootViewController: host)
            window.rootViewController = navigation
            let appeared = appearanceExpectation(
                for: host,
                description: "Home appearance before \(action) pending request"
            )
            window.makeKeyAndVisible()
            defer {
                window.isHidden = true
            }
            guard
                await awaitVisibleHome(
                    appeared,
                    home: host,
                    navigation: navigation,
                    window: window,
                    milestone: "Initial \(action) pending request"
                )
            else {
                return
            }

            sdk.setPresenter(host)
            let task = Task { try await sdk.presentSurvey(slug: "org/survey") }
            await fulfillment(of: [policyStarted], timeout: 5)
            XCTAssertNotNil(reply)
            guard reply != nil else {
                task.cancel()
                return
            }

            XCTAssertNil(sdk.active)
            do {
                _ = try await sdk.presentSurvey(slug: "org/other")
                XCTFail()
            } catch {
                XCTAssertEqual(error as? SkyraError, .alreadyPresenting)
            }
            switch action {
            case "dismiss":
                sdk.dismissSurvey()
            case "cancel":
                task.cancel()
            case "presenter":
                sdk.setPresenter(nil)
            case "navigation":
                navigation.pushViewController(UIViewController(), animated: false)
            default:
                sdk.setSceneActive(false)
            }
            do {
                _ = try await task.value
                XCTFail()
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            XCTAssertNil(sdk.pendingPresentation)
            reply?.resume(returning: PresentationPolicy(
                capturePercent: 100,
                minTimeForRetake: 0,
                minTimeForRetrigger: 0
            ))
            await DecisionTests().flush()
            XCTAssertNil(sdk.active)
            XCTAssertTrue(host.children.isEmpty)
            XCTAssertNil(try sdk.store.storage.update(key: sdk.store.key) { $0 })
        }
    }

    /// Suppression and lookup failures must not create a popup or allocate persisted survey identity.
    func testNotShownAndMetadataFailureHaveNoPresentationOrIdentitySideEffects() async throws {
        let sdk = try makeSDK()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
        }
        for available in [false, true] {
            sdk.loadPolicy = { _, _ in available ? PresentationPolicy(
                capturePercent: 0,
                minTimeForRetake: 0,
                minTimeForRetrigger: 0
            ) : nil }
            let result = try await sdk.presentSurvey(slug: "org/survey", from: host)
            XCTAssertEqual(
                result,
                .notShown(reason: available ? .captureNotSelected : .unavailable)
            )
            XCTAssertNil(sdk.active)
            XCTAssertTrue(host.children.isEmpty)
            XCTAssertNil(try sdk.store.storage.update(key: sdk.store.key) { $0 })
        }
        sdk.loadPolicy = { _, _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await sdk.presentSurvey(slug: "org/survey", from: host)
            XCTFail()
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
        XCTAssertNil(sdk.pendingPresentation)
        XCTAssertNil(try sdk.store.storage.update(key: sdk.store.key) { $0 })
    }

    /// Eligibility uses history as it exists after preflight; fresh restoration cannot bypass completion policy.
    func testHistoryIsReadAfterPreflightAndFreshDoesNotBypassCompletion() async throws {
        let sdk = try makeSDK()
        var reply: CheckedContinuation<PresentationPolicy?, Error>?
        sdk.loadPolicy = { _, _ in try await withCheckedThrowingContinuation { reply = $0 } }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
        }
        let task = Task { try await sdk.presentSurvey(
            slug: "org/survey",
            from: host,
            restoration: .fresh
        ) }
        await DecisionTests().flush()
        try sdk.store.terminal(
            slug: "org/survey",
            visitor: BridgeTests().visitor,
            session: "accepted",
            status: .completed
        )
        let bytes = try sdk.store.storage.update(key: sdk.store.key) { $0 }
        reply?.resume(returning: PresentationPolicy(
            capturePercent: 100,
            minTimeForRetake: nil,
            minTimeForRetrigger: 0
        ))
        let result = try await task.value
        XCTAssertEqual(result, .notShown(reason: .completedCooldown))
        XCTAssertNil(sdk.active)
        XCTAssertEqual(try sdk.store.storage.update(key: sdk.store.key) { $0 }, bytes)
    }

    /// Existing Capture bypasses resampling even when requesting a fresh session.
    func testFreshCaptureDoesNotResample() async throws {
        let sdk = try makeSDK()
        var reply: CheckedContinuation<PresentationPolicy?, Error>?
        sdk.loadPolicy = { _, _ in try await withCheckedThrowingContinuation { reply = $0 } }
        sdk.random = {
            XCTFail("Existing Capture must not resample")
            return 1
        }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
        }
        let state = try StorageTests().state(updated: Clock.nowMilliseconds())
        try sdk.store.save(state)
        let task = Task { try await sdk.presentSurvey(
            slug: "org/survey",
            from: host,
            restoration: .fresh
        ) }
        await DecisionTests().flush()
        reply?.resume(returning: PresentationPolicy(
            capturePercent: 0,
            minTimeForRetake: nil,
            minTimeForRetrigger: nil
        ))
        await DecisionTests().flush()
        await DecisionTests().flush()
        let active = try XCTUnwrap(sdk.active)
        XCTAssertNotEqual(active.bridge.session, state.sessionId)
        XCTAssertTrue(active.initialization.contains("\"savedState\":null"))
        active.finish(.success(.interrupted))
        _ = try await task.value
    }

    /// Different callback orders must converge on one reveal only after capability, layout, and visual readiness.
    func testModernRevealWaitsForCapabilityAppliedLayoutAndVisualReady() async throws {
        for capabilityFirst in [false, true] {
            for visualFirst in [false, true] {
                let sdk = try makeSDK()
                let controller = SurveyController(
                    slug: "org/survey",
                    configuration: sdk.configuration,
                    store: sdk.store,
                    visitor: BridgeTests().visitor,
                    session: "stable-session",
                    initialization: "{}",
                    loadHostedPage: sdk.loadHostedPage
                )
                let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
                let host = UIViewController()
                window.rootViewController = host
                window.makeKeyAndVisible()
                defer {
                    controller.finish(.success(.interrupted))
                    window.isHidden = true
                }
                host.addChild(controller)
                controller.view.frame = host.view.bounds
                host.view.addSubview(controller.view)
                controller.didMove(toParent: host)
                controller.view.layoutIfNeeded()
                XCTAssertFalse(controller.revealed)
                XCTAssertNil(controller.view.hitTest(CGPoint(x: 200, y: 650), with: nil))
                let shadow = try XCTUnwrap(controller.webView.superview?.superview)
                XCTAssertTrue(shadow.accessibilityElementsHidden)
                _ = try BridgeTests().receive(controller.bridge, "ready")
                if capabilityFirst {
                    controller.detectVisualReadiness(true)
                }
                if visualFirst {
                    _ = try BridgeTests().receive(controller.bridge, "visualReady")
                }
                controller.revealIfReady()
                XCTAssertFalse(controller.revealed)
                controller.applyLayout(PopupLayout(
                    contentHeight: 215,
                    cornerRadius: 16,
                    minimized: false,
                    webControls: true
                ))
                XCTAssertFalse(controller.revealed, "Receiving geometry is not applying it")
                await DecisionTests().flush()
                if !visualFirst {
                    _ = try BridgeTests().receive(controller.bridge, "visualReady")
                }
                if !capabilityFirst {
                    controller.revealIfReady()
                    XCTAssertFalse(
                        controller.revealed,
                        "Unknown capability must not use legacy fallback"
                    )
                    controller.detectVisualReadiness(true)
                }
                controller.revealIfReady()
                XCTAssertTrue(controller.revealed)
                XCTAssertEqual(controller.webView.frame.height, 215, accuracy: 1)
                XCTAssertEqual(controller.webView.frame.minY, 0)
                XCTAssertFalse(shadow.accessibilityElementsHidden)
                controller.preparationTimedOut()
                XCTAssertFalse(controller.bridge.finished)
            }
        }
    }

    /// A closed hidden popup must stay hidden; older pages still get a bounded fallback for missing layout.
    func testHiddenTerminalCannotRevealAndLegacyWithoutLayoutIsBounded() async throws {
        for termination in ["timeout", "cancel", "legacy"] {
            let sdk = try makeSDK()
            let controller = SurveyController(
                slug: "org/survey",
                configuration: sdk.configuration,
                store: sdk.store,
                visitor: BridgeTests().visitor,
                session: "stable-session",
                initialization: "{}",
                loadHostedPage: sdk.loadHostedPage
            )
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            let host = UIViewController()
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer {
                controller.finish(.success(.interrupted))
                window.isHidden = true
            }
            host.addChild(controller)
            controller.view.frame = host.view.bounds
            host.view.addSubview(controller.view)
            controller.didMove(toParent: host)
            _ = try BridgeTests().receive(controller.bridge, "ready")
            controller.detectVisualReadiness(termination != "legacy")
            var result: SkyraResult?
            controller.onFinish = { result = try? $0.get() }
            if termination == "legacy" {
                XCTAssertFalse(controller.revealed)
                try await Task.sleep(nanoseconds: 1_100_000_000)
                XCTAssertTrue(controller.revealed)
            } else {
                if termination == "timeout" {
                    controller.preparationTimedOut()
                } else {
                    controller.cancel()
                }
                XCTAssertEqual(
                    result,
                    termination == "timeout" ? .failure("visual_readiness_timeout") : .interrupted
                )
                XCTAssertNil(controller.parent, "Hidden teardown is immediate")
                _ = try BridgeTests().receive(controller.bridge, "visualReady")
                controller.applyLayout(PopupLayout(
                    contentHeight: 215,
                    cornerRadius: 16,
                    minimized: false,
                    webControls: true
                ))
                controller.revealIfReady()
                await DecisionTests().flush()
                XCTAssertFalse(controller.revealed)
            }
        }
    }

    /// Wait for a navigation milestone rather than assuming a number of executor turns.
    private func waitForNavigation(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        _ = try XCTUnwrap(condition() ? true : nil, "Navigation milestone did not complete")
    }

    /// Interruption preserves the last confirmed snapshot and its original retention deadline.
    func testInterruptionPreservesAcknowledgedStateAndExpiry() throws {
        let sdk = try makeSDK()
        let saved = try StorageTests().state(updated: Clock.nowMilliseconds())
        try sdk.store.save(saved)
        let before = try sdk.store.transaction { _ in }.surveys["org/survey"]
        let controller = SurveyController(
            slug: "org/survey",
            configuration: sdk.configuration,
            store: sdk.store,
            visitor: saved.visitorId,
            session: saved.sessionId,
            initialization: "{}",
            loadHostedPage: sdk.loadHostedPage
        )
        var result: SkyraResult?
        controller.onFinish = { result = try? $0.get() }
        controller.interrupt()
        controller.cancel()
        controller.viewDidDisappear(false)
        XCTAssertEqual(result, .interrupted)
        let after = try sdk.store.transaction { _ in }.surveys["org/survey"]
        XCTAssertEqual(before?.active, after?.active)
        XCTAssertEqual(before?.expiresAt, after?.expiresAt)
    }

    /// Every native closing path must preserve completion once the hosted page has accepted the answers.
    func testAcceptedStateSurvivesCloseCancellationAndInterruption() throws {
        for cleanup in [0, 1, 2] {
            let sdk = try makeSDK()
            let saved = try StorageTests().state(
                status: "Completed",
                updated: Clock.nowMilliseconds()
            )
            try sdk.store.save(saved)
            let controller = SurveyController(
                slug: "org/survey",
                configuration: sdk.configuration,
                store: sdk.store,
                visitor: saved.visitorId,
                session: saved.sessionId,
                initialization: "{}",
                loadHostedPage: sdk.loadHostedPage
            )
            let helper = BridgeTests()
            _ = try helper.receive(controller.bridge, "ready")
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(saved))
            _ = controller.bridge.receive(
                try helper.message("state", overrides: ["state": object]),
                mainFrame: true,
                source: controller.bridge.origin,
                now: Clock.nowMilliseconds()
            )
            XCTAssertTrue(controller.bridge.accepted)
            XCTAssertFalse(controller.bridge.finished)
            var result: SkyraResult?
            controller.onFinish = { result = try? $0.get() }
            if cleanup == 0 {
                controller.reject()
            } else if cleanup == 1 {
                controller.cancel()
            } else {
                controller.interrupt()
            }
            XCTAssertEqual(result, .completed)
            let record = try sdk.store.transaction { _ in }.surveys["org/survey"]
            XCTAssertEqual(record?.status, .completed)
            XCTAssertEqual(record?.expiresAt, saved.expiresAt)
        }
    }

    /// Hosted measurements, dragging, keyboard-safe bounds, and rotation must update one live popup consistently.
    func testMeasuredMinimizeChromeAndRotationPreservePresentation() async throws {
        let sdk = try makeSDK()
        let controller = SurveyController(
            slug: "org/survey",
            configuration: sdk.configuration,
            store: sdk.store,
            visitor: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
            session: "stable-session",
            initialization: "{}",
            loadHostedPage: sdk.loadHostedPage
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
        }
        host.addChild(controller)
        controller.view.frame = host.view.bounds
        host.view.addSubview(controller.view)
        controller.didMove(toParent: host)
        controller.view.layoutIfNeeded()
        let helper = BridgeTests()
        _ = controller.bridge.receive(
            try helper.message("ready"),
            mainFrame: true,
            source: controller.bridge.origin,
            now: 0
        )
        controller.detectVisualReadiness(false)
        let saved = try StorageTests().state(updated: Clock.nowMilliseconds())
        try sdk.store.save(saved)
        /// Deliver a layout report and wait for its queued application before checking native frames.
        func apply(
            _ height: Double,
            controls: Bool = true,
            minimized: Bool = false,
            width: Double? = nil
        ) async {
            controller.applyLayout(PopupLayout(
                contentHeight: height,
                cornerRadius: 16,
                minimized: minimized,
                webControls: controls,
                contentWidth: width
            ))
            let applied = expectation(description: "coalesced layout")
            DispatchQueue.main.async { applied.fulfill() }
            await fulfillment(of: [applied], timeout: 1)
            controller.view.layoutIfNeeded()
        }
        await apply(72, minimized: true)
        XCTAssertEqual(controller.webView.frame.height, 72, accuracy: 1)
        XCTAssertEqual(controller.webView.frame.minY, 0)
        XCTAssertTrue(controller.popupLayout?.minimized == true)
        XCTAssertFalse(controller.bridge.finished)
        XCTAssertEqual(try sdk.store.transaction { _ in }.surveys["org/survey"]?.active, saved)
        let compactHeight = controller.webView.frame.height
        await apply(72.01, minimized: true)
        XCTAssertEqual(controller.webView.frame.height, compactHeight)
        await apply(72, minimized: true, width: 150)
        XCTAssertEqual(controller.webView.frame.width, 150, accuracy: 1)
        let narrow = controller.webView.convert(controller.webView.bounds, to: controller.view)
        XCTAssertNil(controller.view.hitTest(
            CGPoint(x: narrow.minX - 10, y: narrow.midY),
            with: nil
        ))
        await apply(72, minimized: true, width: 190)
        XCTAssertEqual(controller.webView.frame.width, 190, accuracy: 1)
        controller.movePopup(to: CGPoint(x: 320, y: 400))
        await apply(72, width: 190)
        XCTAssertGreaterThan(controller.webView.frame.width, 190)
        XCTAssertEqual(controller.placement.desiredCorner, CGPoint(x: 320, y: 400))
        let bar = UITabBar(frame: CGRect(x: 0, y: 500, width: 390, height: 60))
        host.view.insertSubview(bar, belowSubview: controller.view)
        controller.movePopup(to: CGPoint(x: 320, y: 750))
        let obstructed = controller.webView.convert(controller.webView.bounds, to: controller.view)
        XCTAssertLessThanOrEqual(obstructed.maxY, 484)
        bar.removeFromSuperview()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        XCTAssertEqual(controller.placement.desiredCorner, CGPoint(x: 320, y: 750))
        await apply(200, controls: false)
        XCTAssertEqual(controller.webView.frame.minY, 48)
        XCTAssertEqual(controller.webView.frame.height, 200, accuracy: 1)
        controller.applyLayout(PopupLayout(
            contentHeight: 250,
            cornerRadius: 16,
            minimized: false,
            webControls: true
        ))
        await apply(280)
        XCTAssertEqual(controller.webView.frame.height, 280, accuracy: 1)
        await apply(10_000)
        XCTAssertLessThan(controller.webView.frame.height, 844)
        controller.view.frame = CGRect(x: 0, y: 0, width: 844, height: 390)
        controller.view.layoutIfNeeded()
        XCTAssertLessThanOrEqual(controller.webView.frame.width, 400)
        XCTAssertLessThan(controller.webView.frame.height, 390)
        XCTAssertTrue(controller.webView.scrollView.isScrollEnabled)
        await apply(72)
        XCTAssertEqual(controller.webView.frame.height, 72, accuracy: 1)
        let done = expectation(description: "animated teardown")
        var calls = 0
        controller.onFinish = { _ in calls += 1
            done.fulfill()
        }
        controller.finish(.success(.unavailable))
        XCTAssertTrue(controller.bridge.finished)
        XCTAssertNotNil(controller.parent)
        controller.finish(.success(.completed))
        controller.cancel()
        await apply(300)
        XCTAssertEqual(controller.popupLayout?.contentHeight, 72)
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(calls, 1)
        XCTAssertNil(controller.parent)
    }

    /// Native text-size conversion must remain within the hosted page's supported scale range.
    func testDynamicTypeScaleBounds() {
        XCTAssertEqual(
            SurveyController.textScale(
                for: UITraitCollection(preferredContentSizeCategory: .extraSmall)
            ),
            1
        )
        let large =
            SurveyController.textScale(
                for: UITraitCollection(
                    preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge
                )
            )
        XCTAssertGreaterThan(large, 1)
        XCTAssertLessThanOrEqual(large, 3)
    }

    /// A second survey cannot attach until the first popup's exit animation has actually removed it.
    func testActiveSlotStaysReservedDuringTerminalAnimation() async throws {
        let sdk = try makeSDK()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
        }
        let task = Task { try await sdk.presentSurvey(slug: "org/survey", from: host) }
        let controller = try await attachedPopup(sdk)
        let helper = BridgeTests()
        _ = controller.bridge.receive(
            try helper.message("ready", overrides: [
                "visitorId": controller.bridge.visitor,
                "sessionId": controller.bridge.session,
            ]),
            mainFrame: true,
            source: controller.bridge.origin,
            now: 0
        )
        controller.detectVisualReadiness(false)
        controller.applyLayout(PopupLayout(
            contentHeight: 200,
            cornerRadius: 16,
            minimized: false,
            webControls: true
        ))
        await DecisionTests().flush()
        XCTAssertTrue(controller.revealed)
        controller.finish(.success(.unavailable))
        XCTAssertTrue(sdk.active === controller)
        do {
            _ = try await sdk.presentSurvey(slug: "org/survey", from: host)
            XCTFail()
        } catch {
            XCTAssertEqual(error as? SkyraError, .alreadyPresenting)
        }
        task.cancel()
        controller.finish(.success(.completed))
        let result = try await task.value
        XCTAssertEqual(result, .unavailable)
        XCTAssertNil(sdk.active)
        XCTAssertNil(controller.parent)
    }

    /// Requests that cannot start must fail before claiming active presentation ownership.
    func testUnattachedPresenterAndPrecancelledTaskDoNotReserveSlot() async throws {
        let sdk = try makeSDK()
        do {
            _ = try await sdk.presentSurvey(slug: "org/survey", from: UIViewController())
            XCTFail("Expected presenter error")
        } catch {
            XCTAssertEqual(error as? SkyraError, .presenterUnavailable)
        }
        let task = Task { try await sdk.presentSurvey(slug: "org/survey", from: UIViewController())
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail()
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertNil(sdk.active)
    }

    /// View-task cancellation preserves history and delivers one result despite later terminal calls.
    func testCancellationBeforeLoadingPreservesProgressAndCleansOnce() throws {
        let sdk = try makeSDK()
        try sdk.store.save(StorageTests().state(updated: Clock.nowMilliseconds()))
        let before = try sdk.store.history(slug: "org/survey")
        let controller = SurveyController(
            slug: "org/survey",
            configuration: sdk.configuration,
            store: sdk.store,
            visitor: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
            session: "s",
            initialization: "{}",
            loadHostedPage: sdk.loadHostedPage
        )
        var calls = 0
        controller.onFinish = { result in
            calls += 1
            XCTAssertEqual(try? result.get(), .interrupted)
        }
        controller.cancel()
        controller.reject()
        controller.finish(.success(.completed))
        XCTAssertEqual(calls, 1)
        let record = try XCTUnwrap(sdk.store.transaction { _ in }.surveys["org/survey"])
        XCTAssertEqual(record.status, .capture)
        XCTAssertEqual(record.active, before?.active)
        XCTAssertNil(controller.onFinish)
    }

    /// A terminal callback may reenter finish. The controller must close message handling before notifying it,
    /// preserving the first outcome and preventing a second cleanup from changing storage or the callback.
    func testReentrantTerminalCallbackDoesNotRepeatTeardown() throws {
        let sdk = try makeSDK()
        let controller = SurveyController(
            slug: "org/survey",
            configuration: sdk.configuration,
            store: sdk.store,
            visitor: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
            session: "s",
            initialization: "{}",
            loadHostedPage: sdk.loadHostedPage
        )
        var finishCalls = 0
        var outcome: SkyraResult?
        controller.onFinish = { result in
            finishCalls += 1
            outcome = try? result.get()
        }

        controller.finish(.success(.completed))
        controller.finish(.success(.rejected))

        XCTAssertEqual(finishCalls, 1)
        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(try sdk.store.history(slug: "org/survey")?.status, .completed)
        XCTAssertTrue(controller.bridge.finished)
        XCTAssertNil(controller.onFinish)
    }

    /// Native state uses a nonpersistent WebView; rejection must remove handlers so the controller can deallocate.
    func testWebViewUsesNativeAuthorityAndRejectCleansHandlerCycle() async throws {
        let sdk = try makeSDK()
        var controller: SurveyController? = SurveyController(
            slug: "org/survey",
            configuration: sdk.configuration,
            store: sdk.store,
            visitor: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
            session: "s",
            initialization: "{}",
            loadHostedPage: sdk.loadHostedPage
        )
        weak var weakController = controller
        controller?.loadViewIfNeeded()
        XCTAssertFalse(controller!.webView.configuration.websiteDataStore.isPersistent)
        let done = expectation(description: "dismiss")
        controller?.onFinish = { _ in done.fulfill() }
        controller?.reject()
        await fulfillment(of: [done], timeout: 2)
        XCTAssertNil(controller?.webView.navigationDelegate)
        controller = nil
        XCTAssertNil(weakController)
    }

    /// The floating popup leaves surrounding app controls interactive and closes once through accessibility escape.
    func testPopupLeavesAppInteractiveAndEscapeRemovesChildOnce() async throws {
        let sdk = try makeSDK()
        let controller = SurveyController(
            slug: "org/survey",
            configuration: sdk.configuration,
            store: sdk.store,
            visitor: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
            session: "popup",
            initialization: "{}",
            loadHostedPage: sdk.loadHostedPage
        )
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
        }
        let appButton = UIButton(frame: CGRect(x: 8, y: 80, width: 100, height: 44))
        host.view.addSubview(appButton)
        host.addChild(controller)
        controller.view.frame = host.view.bounds
        host.view.addSubview(controller.view)
        controller.didMove(toParent: host)
        controller.view.layoutIfNeeded()
        XCTAssertNil(host.presentedViewController)
        XCTAssertTrue(window.hitTest(CGPoint(x: 20, y: 100), with: nil) === appButton)
        let done = expectation(description: "popup dismissed")
        var calls = 0
        controller.onFinish = { result in
            calls += 1
            if case .success(.rejected) = result {} else {
                XCTFail("Expected rejection")
            }
            done.fulfill()
        }
        XCTAssertTrue(controller.accessibilityPerformEscape())
        controller.reject()
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(calls, 1)
        let record = try XCTUnwrap(sdk.store.transaction { _ in }.surveys["org/survey"])
        XCTAssertEqual(record.status, .rejected)
        XCTAssertNil(record.active)
        XCTAssertNil(controller.webView.navigationDelegate)
        XCTAssertNil(controller.parent)
        XCTAssertNil(controller.view.superview)
    }
}
#endif
