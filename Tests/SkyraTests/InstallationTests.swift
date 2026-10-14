// Exercise the public convenience APIs through real UIKit/SwiftUI appearance lifetimes.
#if canImport(UIKit)
import SwiftUI
import UIKit
import XCTest
@testable import Skyra

@MainActor
final class InstallationTests: XCTestCase {
    final class Model: ObservableObject {
        @Published var visible = true
        @Published var revision = 0
        @Published var slug = "org/survey"
        @Published var phase: ScenePhase = .active
        var screenVisible = false
        var observedPhase: ScenePhase?
    }

    struct Screen: View {
        @ObservedObject var model: Model
        let outcome: (SkyraResult) -> Void
        var body: some View {
            VStack {
                Text("Revision \(model.revision)")
                if model.visible {
                    Text("Survey screen").skyraSurvey(model.slug, onOutcome: outcome)
                        .onAppear { model.screenVisible = true }
                        .onDisappear { model.screenVisible = false }
                }
            }
        }
    }

    struct Probe: View {
        @Environment(\.skyraInstallation) var installation
        let revision: Int
        let observed: (SkyraInstallation?) -> Void
        var body: some View {
            Text("Root \(revision)")
                .onAppear { observed(installation) }
                .onChange(of: revision) { _ in observed(installation) }
        }
    }

    struct PhaseRoot: View {
        @ObservedObject var model: Model
        let installation: SkyraInstallation
        let outcome: (SkyraResult) -> Void

        var body: some View {
            Screen(model: model, outcome: outcome)
                .modifier(ExplicitRootModifier(installation: installation))
                .environment(\.scenePhase, model.phase)
                .onAppear { model.observedPhase = model.phase }
                .onChange(of: model.phase) { model.observedPhase = $0 }
        }
    }

    private func sceneWindow() throws -> UIWindow {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive },
            "Installation lifecycle test requires a foreground-active UIWindowScene"
        )
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        return window
    }

    func window(root: UIViewController) throws -> UIWindow {
        let window = try sceneWindow()
        window.rootViewController = root
        window.makeKeyAndVisible()
        postActivity(in: window, active: true)
        return window
    }

    private func postActivity(
        in window: UIWindow,
        active: Bool,
        center: NotificationCenter = .default
    ) {
        if let scene = window.windowScene {
            center.post(
                name: active ? UIScene.didActivateNotification :
                    UIScene.didEnterBackgroundNotification,
                object: scene
            )
        } else {
            center.post(
                name: active ? UIApplication.didBecomeActiveNotification :
                    UIApplication.didEnterBackgroundNotification,
                object: nil
            )
        }
    }

    private func wait(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(condition(), "Lifecycle milestone did not complete", file: file, line: line)
    }

    private func reveal(_ popup: SurveyController) async throws {
        let bridgeTests = BridgeTests()
        let identity: [String: Any] = [
            "visitorId": popup.bridge.visitor,
            "sessionId": popup.bridge.session,
            "slug": popup.bridge.slug,
        ]
        _ = try bridgeTests.receive(popup.bridge, "ready", identity)
        _ = try bridgeTests.receive(popup.bridge, "visualReady", identity)
        popup.detectVisualReadiness(true)
        popup.applyLayout(PopupLayout(
            contentHeight: 220,
            cornerRadius: 16,
            minimized: false,
            webControls: true
        ))
        try await wait { popup.revealed }
    }

    private func shownScreenPopup(_ sdk: Skyra) async throws -> SurveyController {
        try await wait { sdk.screenCandidateController != nil }
        let popup = try XCTUnwrap(sdk.screenCandidateController)
        try await reveal(popup)
        XCTAssertTrue(sdk.active === popup)
        return popup
    }

    func testUIKitWindowOwnsOneSDKAndConfigurationIsStable() throws {
        let first = UIWindow()
        let second = UIWindow()
        let installation = Skyra.install(
            in: first,
            configuration: .init(language: "en", persistence: .ephemeral)
        )
        let repeated = Skyra.install(in: first, configuration: .init(language: "nb"))
        XCTAssertTrue(installation === repeated)
        XCTAssertEqual(repeated.sdk?.configuration.language, "en")
        XCTAssertFalse(installation === Skyra.install(in: second))
        weak var retained: SkyraInstallation?
        var owner: UIWindow? = UIWindow()
        retained = Skyra.install(in: owner!)
        XCTAssertNotNil(retained)
        owner = nil
        XCTAssertNil(retained)
    }

    func testUIKitAttachmentDepartureReentryAndDetach() async throws {
        let screen = UIViewController()
        let navigation = UINavigationController(rootViewController: screen)
        // Attach before installation/appearance, as in viewDidLoad.
        var outcomes: [SkyraResult] = []
        let attachment = screen.skyraSurvey("org/survey", onOutcome: { outcomes.append($0) })
        let window = try sceneWindow()
        window.rootViewController = navigation
        let sdk = try XCTUnwrap(Skyra.install(
            in: window,
            configuration: .init(persistence: .ephemeral)
        ).sdk)
        sdk.loadPolicy = { _, _ in PresentationPolicy(
            capturePercent: 100,
            minTimeForRetake: 0,
            minTimeForRetrigger: 0
        ) }
        var requests: [URLRequest] = []
        try sdk.store.save(StorageTests().state(updated: Clock.nowMilliseconds()))
        sdk.loadHostedPage = { _, request in requests.append(request) }
        window.makeKeyAndVisible()
        postActivity(in: window, active: true)
        defer { attachment.detach()
            window.isHidden = true
        }
        let popup = try await shownScreenPopup(sdk)
        let session = popup.bridge.session
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.url?.path, "/app.html")
        navigation.pushViewController(UIViewController(), animated: false)
        try await wait { sdk.active == nil && outcomes.count == 1 }
        XCTAssertEqual(outcomes, [.interrupted])
        navigation.popViewController(animated: false)
        let resumed = try await shownScreenPopup(sdk)
        XCTAssertEqual(resumed.bridge.session, session)
        XCTAssertEqual(requests.count, 2)
        attachment.detach()
        try await wait { sdk.active == nil && outcomes.count == 2 }
        XCTAssertNil(attachment.parent)
    }

    func testUIKitMissingRootAndInitializationFailureLeaveScreenUsable() async throws {
        for invalid in [false, true] {
            let screen = UIViewController()
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.rootViewController = screen
            var initializationErrors: [Error] = []
            if invalid {
                let installation = Skyra.install(
                    in: window,
                    configuration: .init(hostedOrigin: URL(string: "http://invalid.example")!),
                    onError: { initializationErrors.append($0) }
                )
                XCTAssertNil(installation.sdk)
                XCTAssertEqual(initializationErrors.first as? SkyraError, .invalidConfiguration)
            }
            var errors: [Error] = []
            let attachment = screen.skyraSurvey("org/survey", onError: { errors.append($0) })
            window.makeKeyAndVisible()
            defer { attachment.detach()
                window.isHidden = true
            }
            try await wait { errors.count == 1 }
            if invalid {
                XCTAssertEqual(errors.first as? SkyraError, .invalidConfiguration)
            } else {
                XCTAssertEqual(errors.first as? SkyraIntegrationError, .missingRoot)
            }
            XCTAssertTrue(screen.view.isUserInteractionEnabled)
            XCTAssertFalse(attachment.view.isUserInteractionEnabled)
            XCTAssertNil(screen.presentedViewController)
        }
    }

    func testSwiftUIRootRetainsSDKAcrossReconstructionAndSeparatesWindows() async throws {
        var observations: [SkyraInstallation] = []
        let observed: (SkyraInstallation?)
            -> Void = {
                if let value = $0 {
                    observations.append(value)
                }
            }
        let host =
            UIHostingController(rootView: Probe(
                revision: 0,
                observed: observed
            ).skyra(configuration: .init(
                language: "en",
                persistence: .ephemeral
            )))
        let first = try window(root: host)
        defer { first.isHidden = true }
        try await wait { observations.count == 1 }
        host.rootView = Probe(revision: 1, observed: observed).skyra(configuration: .init(
            language: "nb",
            persistence: .ephemeral
        ))
        try await wait { observations.count == 2 }
        XCTAssertTrue(observations[0] === observations[1])
        XCTAssertEqual(observations[1].sdk?.configuration.language, "en")
        let second = try window(root: UIHostingController(rootView: Probe(
            revision: 0,
            observed: observed
        ).skyra()))
        defer { second.isHidden = true }
        try await wait { observations.count == 3 }
        XCTAssertFalse(observations[0] === observations[2])
        XCTAssertFalse(observations[0].sdk === observations[2].sdk)
    }

    func testSwiftUIScreenEntryDepartureReentryAndRootReentry() async throws {
        let sdk = try PresentationTests().makeSDK()
        try sdk.store.save(StorageTests().state(updated: Clock.nowMilliseconds()))
        let installation = SkyraInstallation(sdk: sdk)
        let model = Model()
        var outcomes: [SkyraResult] = []
        let root = Screen(
            model: model,
            outcome: { outcomes.append($0)
            }
        ).modifier(ExplicitRootModifier(installation: installation))
            .environment(\.scenePhase, .active)
        let host = UIHostingController(rootView: root)
        let navigation = UINavigationController(rootViewController: host)
        let window = try window(root: navigation)
        defer { window.isHidden = true }
        let first = try await shownScreenPopup(sdk)
        model.revision += 1
        await DecisionTests().flush()
        XCTAssertTrue(sdk.active === first, "Redraw must not re-request")
        model.visible = false
        try await wait { sdk.active == nil && outcomes.count == 1 }
        XCTAssertEqual(outcomes, [.interrupted])
        model.visible = true
        let second = try await shownScreenPopup(sdk)
        XCTAssertEqual(second.bridge.session, first.bridge.session)
        navigation.pushViewController(UIViewController(), animated: false)
        try await wait { sdk.active == nil && outcomes.count == 2 }
        navigation.popViewController(animated: false)
        _ = try await shownScreenPopup(sdk)
        model.visible = false
        try await wait { sdk.active == nil && outcomes.count == 3 }
    }

    func testSwiftUIScreenCooldownDoesNotDisplaceFollowingPopup() async throws {
        let configuration = SkyraConfiguration(
            persistence: .ephemeral,
            surveyDecision: { context in
                if context.requestedSlug == "org/b" {
                    return .notShown(.rejectedCooldown)
                }
                return .present(slug: "org/a")
            }
        )
        let model = Model()
        model.visible = false
        model.slug = "org/b"
        var installation: SkyraInstallation?
        var bOutcomes: [SkyraResult] = []
        var aOutcomes: [SkyraResult] = []
        let root = VStack {
            Probe(revision: 0, observed: { installation = $0 })
            Screen(model: model, outcome: { bOutcomes.append($0) })
        }
        .skyra(configuration: configuration)
        .environment(\.scenePhase, .active)
        let window = try window(root: UIHostingController(rootView: root))
        defer { window.isHidden = true }
        try await wait { installation != nil }
        let sdk = try XCTUnwrap(installation?.sdk)
        sdk.loadHostedPage = { _, _ in }
        let aHandle = try XCTUnwrap(installation).presentSurvey(
            slug: "org/a",
            onOutcome: { aOutcomes.append($0) }
        )
        let a = try await PresentationTests().attachedPopup(sdk)
        let aWebView = a.webView

        model.visible = true
        try await wait { bOutcomes.count == 1 }

        XCTAssertEqual(bOutcomes, [.notShown(reason: .rejectedCooldown)])
        XCTAssertTrue(sdk.active === a)
        XCTAssertTrue(a.webView === aWebView)
        XCTAssertFalse(a.view.isHidden)
        XCTAssertNil(sdk.parkedFollowing)
        XCTAssertNil(sdk.screenPriorityVisit)
        XCTAssertTrue(aOutcomes.isEmpty)
        aHandle.cancel()
    }

    func testSwiftUIScreenOwnsShownLeaseUntilItsViewDeparts() async throws {
        let configuration = SkyraConfiguration(
            persistence: .ephemeral,
            surveyDecision: { context in .present(slug: context.requestedSlug ?? "org/a") }
        )
        let model = Model()
        model.visible = false
        model.slug = "org/b"
        var installation: SkyraInstallation?
        var aOutcomes: [SkyraResult] = []
        var bOutcomes: [SkyraResult] = []
        let root = VStack {
            Probe(revision: 0, observed: { installation = $0 })
            Screen(model: model, outcome: { bOutcomes.append($0) })
        }
        .skyra(configuration: configuration)
        .environment(\.scenePhase, .active)
        let window = try window(root: UIHostingController(rootView: root))
        defer { window.isHidden = true }
        try await wait { installation != nil }
        let resolvedInstallation = try XCTUnwrap(installation)
        let sdk = try XCTUnwrap(resolvedInstallation.sdk)
        sdk.loadHostedPage = { _, _ in }
        let aHandle = resolvedInstallation.presentSurvey(
            slug: "org/a",
            onOutcome: { aOutcomes.append($0) }
        )
        let a = try await PresentationTests().attachedPopup(sdk)
        try await reveal(a)
        let aWebView = a.webView
        let aSession = a.bridge.session

        model.visible = true
        try await wait { sdk.screenCandidateController != nil }
        let b: SurveyController = try XCTUnwrap(sdk.screenCandidateController)
        try await reveal(b)
        XCTAssertTrue(sdk.active === b)
        XCTAssertTrue(sdk.parkedFollowing === a)
        XCTAssertTrue(a.view.isHidden)
        XCTAssertTrue(aOutcomes.isEmpty)
        b.finish(.success(SkyraResult.completed))
        try await wait { sdk.active == nil && bOutcomes == [.completed] }
        XCTAssertEqual(sdk.screenPriorityVisit != nil, true)
        XCTAssertTrue(sdk.parkedFollowing === a)

        model.visible = false
        try await wait { sdk.active === a && sdk.parkedFollowing == nil }
        XCTAssertNil(sdk.screenPriorityVisit)
        XCTAssertFalse(a.view.isHidden)
        XCTAssertTrue(a.webView === aWebView)
        XCTAssertEqual(a.bridge.session, aSession)
        XCTAssertTrue(aOutcomes.isEmpty)
        aHandle.cancel()
    }

    func testSwiftUIMissingRootAndFailedInitializationReportThroughPublicModifiers() async throws {
        var errors: [Error] = []
        let missing = try window(root: UIHostingController(rootView: Text("Screen").skyraSurvey(
            "org/survey",
            onError: { errors.append($0) }
        )))
        defer { missing.isHidden = true }
        try await wait { errors.count == 1 }
        XCTAssertEqual(errors.first as? SkyraIntegrationError, .missingRoot)
        var rootErrors: [Error] = []
        var screenErrors: [Error] = []
        let invalid = Text("Still usable")
            .skyraSurvey("org/survey", onError: { screenErrors.append($0) })
            .skyra(
                configuration: .init(hostedOrigin: URL(string: "http://invalid.example")!),
                onError: { rootErrors.append($0) }
            )
        let failed = try window(root: UIHostingController(rootView: invalid))
        defer { failed.isHidden = true }
        try await wait { rootErrors.count == 1 && screenErrors.count == 1 }
        XCTAssertEqual(rootErrors.first as? SkyraError, .invalidConfiguration)
        XCTAssertEqual(screenErrors.first as? SkyraError, .invalidConfiguration)
        XCTAssertNotNil(failed.rootViewController?.view)
    }

    func testSwiftUISlugReplacementCancelsPreviousRequestBeforeStartingNext() async throws {
        let sdk = try PresentationTests().makeSDK()
        let model = Model()
        var outcomes: [SkyraResult] = []
        let root = Screen(model: model, outcome: { outcomes.append($0) })
            .modifier(ExplicitRootModifier(installation: SkyraInstallation(sdk: sdk)))
            .environment(\.scenePhase, .active)
        let window = try window(root: UIHostingController(rootView: root))
        defer { window.isHidden = true }
        _ = try await shownScreenPopup(sdk)
        model.slug = "org/replacement"
        let replacement = try await shownScreenPopup(sdk)
        XCTAssertEqual(replacement.bridge.slug, "org/replacement")
        try await wait { sdk.active?.bridge.slug == "org/replacement" }
        XCTAssertEqual(outcomes, [.interrupted])
        model.visible = false
        try await wait { sdk.active == nil && outcomes.count == 2 }
    }

    func testUIKitDepartureCancelsPendingLookupAndLateReplyCannotOpenPopup() async throws {
        let screen = UIViewController()
        let navigation = UINavigationController(rootViewController: screen)
        let window = try sceneWindow()
        window.rootViewController = navigation
        let sdk = try XCTUnwrap(Skyra.install(
            in: window,
            configuration: .init(persistence: .ephemeral)
        ).sdk)
        sdk.loadHostedPage = { _, _ in XCTFail("Cancelled preflight must not load a page") }
        var reply: CheckedContinuation<PresentationPolicy?, Error>?
        sdk.loadPolicy = { _, _ in try await withCheckedThrowingContinuation { reply = $0 } }
        let attachment = screen.skyraSurvey(
            "org/survey",
            onError: { XCTFail("Normal departure: \($0)") }
        )
        window.makeKeyAndVisible()
        postActivity(in: window, active: true)
        defer { attachment.detach()
            window.isHidden = true
        }
        try await wait { reply != nil }
        navigation.pushViewController(UIViewController(), animated: false)
        try await wait { sdk.screenCandidatePending == nil }
        reply?.resume(returning: PresentationPolicy(
            capturePercent: 100,
            minTimeForRetake: 0,
            minTimeForRetrigger: 0
        ))
        await DecisionTests().flush()
        XCTAssertNil(sdk.active)
        XCTAssertNil(sdk.screenCandidateController)
        XCTAssertNil(try sdk.store.storage.update(key: sdk.store.key) { $0 })
    }

    func testSwiftUIInitialInactiveEntryWaitsAndForegroundDoesNotReplayAttempt() async throws {
        for initialPhase in [ScenePhase.inactive, .background] {
            let sdk = try PresentationTests().makeSDK()
            let model = Model()
            model.phase = initialPhase
            var lookups = 0
            var outcomes: [SkyraResult] = []
            sdk.loadPolicy = { _, _ in lookups += 1
                return nil
            }
            let root = PhaseRoot(
                model: model,
                installation: SkyraInstallation(sdk: sdk),
                outcome: { outcomes.append($0) }
            )
            let window = try window(root: UIHostingController(rootView: root))
            defer { window.isHidden = true }
            await DecisionTests().flush()
            XCTAssertFalse(sdk.sceneActive)
            XCTAssertEqual(lookups, 0)
            XCTAssertNil(sdk.pendingPresentation)
            XCTAssertNil(try sdk.store.storage.update(key: sdk.store.key) { $0 })
            model.phase = .active
            try await wait { outcomes.count == 1 }
            XCTAssertEqual(lookups, 1)
            model.phase = .inactive
            try await wait { model.observedPhase == .inactive && !sdk.sceneActive }
            model.phase = .background
            try await wait { model.observedPhase == .background }
            model.phase = .active
            try await wait { sdk.sceneActive }
            await DecisionTests().flush()
            XCTAssertEqual(lookups, 1, "Foreground alone must not replay a finished attempt")
            model.visible = false
            try await wait { !model.screenVisible }
            model.visible = true
            try await wait { outcomes.count == 2 }
        }
    }

    func testSwiftUIInactiveDepartureCancelsWaitAndBackgroundCancelsStartedDelay() async throws {
        let sdk = try PresentationTests().makeSDK()
        let model = Model()
        model.phase = .background
        var lookups = 0
        var delay: CheckedContinuation<Void, Error>?
        sdk.loadPolicy = { _, _ in
            lookups += 1
            return PresentationPolicy(
                capturePercent: 100,
                minTimeForRetake: 0,
                minTimeForRetrigger: 0,
                initialDelayMilliseconds: 5000
            )
        }
        sdk.waitForDelay = { _ in try await withCheckedThrowingContinuation { delay = $0 } }
        sdk.loadHostedPage = { _, _ in XCTFail("Inactive request must not load") }
        let root = PhaseRoot(
            model: model,
            installation: SkyraInstallation(sdk: sdk),
            outcome: { _ in XCTFail("Preflight cancellation is silent") }
        )
        let window = try window(root: UIHostingController(rootView: root))
        defer { window.isHidden = true }
        await DecisionTests().flush()
        model.visible = false
        await DecisionTests().flush()
        model.phase = .active
        try await wait { sdk.sceneActive }
        XCTAssertEqual(lookups, 0, "Departure must cancel the activation wait")
        model.visible = true
        try await wait { delay != nil }
        model.phase = .background
        try await wait { !sdk.sceneActive && sdk.pendingPresentation == nil }
        delay?.resume()
        model.phase = .active
        try await wait { sdk.sceneActive }
        await DecisionTests().flush()
        XCTAssertEqual(lookups, 1)
        XCTAssertNil(sdk.active)
        XCTAssertNil(try sdk.store.storage.update(key: sdk.store.key) { $0 })
    }

    func testUIKitWindowBackgroundCancelsPendingLookupAndDelayWithoutDisappearance() async throws {
        for delaying in [false, true] {
            let center = NotificationCenter()
            let screen = UIViewController()
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.rootViewController = screen
            let installation = Skyra.install(
                in: window,
                configuration: .init(persistence: .ephemeral)
            )
            installation.observeActivity(in: window, center: center)
            let sdk = try XCTUnwrap(installation.sdk)
            var lookups = 0
            var lookup: CheckedContinuation<PresentationPolicy?, Error>?
            var delay: CheckedContinuation<Void, Error>?
            let policy = PresentationPolicy(
                capturePercent: 100,
                minTimeForRetake: 0,
                minTimeForRetrigger: 0,
                initialDelayMilliseconds: 5000
            )
            sdk.loadPolicy = { _, _ in
                lookups += 1
                if delaying {
                    return policy
                }
                return try await withCheckedThrowingContinuation { lookup = $0 }
            }
            sdk.waitForDelay = { _ in try await withCheckedThrowingContinuation { delay = $0 } }
            sdk.loadHostedPage = { _, _ in XCTFail("Background cancellation must prevent loading") }
            let attachment = screen.skyraSurvey(
                "org/survey",
                onError: { XCTFail("Unexpected error: \($0)") }
            )
            window.makeKeyAndVisible()
            defer { attachment.detach()
                window.isHidden = true
            }
            postActivity(in: window, active: false, center: center)
            await DecisionTests().flush()
            XCTAssertEqual(lookups, 0, "Initial inactive appearance waits for activation")
            postActivity(in: window, active: true, center: center)
            try await wait { delaying ? delay != nil : lookup != nil }
            center.post(
                name: UIScene.didEnterBackgroundNotification,
                object: NSObject()
            )
            XCTAssertTrue(sdk.sceneActive, "Other scenes must not cancel this request")
            postActivity(in: window, active: false, center: center)
            XCTAssertFalse(sdk.sceneActive, "Notification must close the gate synchronously")
            try await wait { sdk.pendingPresentation == nil }
            lookup?.resume(returning: policy)
            delay?.resume()
            postActivity(in: window, active: true, center: center)
            await DecisionTests().flush()
            XCTAssertEqual(lookups, 1)
            XCTAssertNil(sdk.active)
            XCTAssertTrue(screen.view.window === window, "No view disappearance was used")
            XCTAssertNil(try sdk.store.storage.update(key: sdk.store.key) { $0 })
        }
    }

    func testSwiftUISceneLossInterruptsActiveAttemptAndNeverReplaysCompletedAttempt() async throws {
        for completed in [false, true] {
            let sdk = try PresentationTests().makeSDK()
            let model = Model()
            var outcomes: [SkyraResult] = []
            var lookups = 0
            sdk.loadPolicy = { _, _ in
                lookups += 1
                return PresentationPolicy(
                    capturePercent: 100,
                    minTimeForRetake: 0,
                    minTimeForRetrigger: 0
                )
            }
            let root = PhaseRoot(
                model: model,
                installation: SkyraInstallation(sdk: sdk),
                outcome: { outcomes.append($0) }
            )
            let window = try window(root: UIHostingController(rootView: root))
            defer { window.isHidden = true }
            let popup = try await shownScreenPopup(sdk)
            if completed {
                popup.finish(.success(.completed))
                try await wait { outcomes.count == 1 }
            }
            model.phase = .inactive
            try await wait { !sdk.sceneActive && sdk.active == nil && outcomes.count == 1 }
            XCTAssertEqual(outcomes, [completed ? .completed : .interrupted])
            model.phase = .active
            try await wait { sdk.sceneActive }
            await DecisionTests().flush()
            XCTAssertEqual(lookups, 1)
            XCTAssertNil(sdk.active)
        }
    }

    func testSceneObserverFiltersOtherScenesAndReleasesRegistration() throws {
        let center = NotificationCenter()
        // Tokens exercise the same NotificationCenter object filter used with window.windowScene,
        // without depending on the test host having two independently connected UIWindowScenes.
        let ownScene = NSObject()
        let otherScene = NSObject()
        let sdk = try PresentationTests().makeSDK()
        let installation = SkyraInstallation(sdk: sdk)
        var changes = 0
        var observer: InstallationActivityObserver? = InstallationActivityObserver(
            scope: ownScene,
            center: center,
            initiallyActive: false
        ) {
            changes += 1
            installation.setActive($0)
        }
        weak var released = observer
        XCTAssertFalse(sdk.sceneActive)
        center.post(name: UIScene.didActivateNotification, object: otherScene)
        XCTAssertFalse(sdk.sceneActive)
        center.post(name: UIScene.didActivateNotification, object: ownScene)
        XCTAssertTrue(sdk.sceneActive)
        center.post(
            name: UIScene.didEnterBackgroundNotification,
            object: otherScene
        )
        center.post(
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        XCTAssertTrue(sdk.sceneActive)
        center.post(name: UIScene.willDeactivateNotification, object: ownScene)
        XCTAssertFalse(sdk.sceneActive)
        observer = nil
        XCTAssertNil(released)
        let previous = changes
        center.post(name: UIScene.didActivateNotification, object: ownScene)
        XCTAssertEqual(changes, previous)
    }

    func testLegacyActivityObserverUsesOnlyApplicationLifecycle() {
        let center = NotificationCenter()
        var active = false
        let observer = InstallationActivityObserver(
            scope: nil,
            center: center,
            initiallyActive: true
        ) {
            active = $0
        }
        XCTAssertTrue(active)
        center.post(
            name: UIScene.didEnterBackgroundNotification,
            object: NSObject()
        )
        XCTAssertTrue(active)
        center.post(
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        XCTAssertFalse(active)
        center.post(
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        XCTAssertTrue(active)
        withExtendedLifetime(observer) {}
    }
}
#endif
