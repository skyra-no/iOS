// Shared ownership for explicit SwiftUI and UIKit installations. No route selection is performed.
#if canImport(UIKit)
import SwiftUI
import UIKit
import ObjectiveC

/// A root retains one SDK, including ephemeral state, for its lifetime.
/// Configuration is captured on first installation; recreate the SwiftUI root identity or UIKit
/// window to change it. Repeated installation calls retain the original configuration and callback.
@MainActor
public final class SkyraInstallation: ObservableObject {
    /// The configured SDK, or nil if configuration validation failed.
    public let sdk: Skyra?
    let initializationError: Error?
    private let onError: ((Error) -> Void)?
    private var reportedInitialization = false
    private var active = false
    private var following: SkyraSurveyRequest?
    private var followingTask: Task<Void, Never>?
    private var followingPending: PendingPresentation?

    /// Trigger one explicit survey owned by this installation, independently of the calling view.
    /// Navigation keeps the live session; scene inactivity suspends it and UIKit coverage hides it naturally.
    /// Errors are reported through onError. Retain the optional handle only to interrupt later.
    @discardableResult
    public func presentSurvey(
        slug: String,
        restoration: Skyra.Restoration = .resumeInterrupted,
        onOutcome: ((SkyraResult) -> Void)? = nil,
        onError: ((Error) -> Void)? = nil
    ) -> SkyraSurveyRequest {
        presentSurvey(
            slug: Optional(slug),
            restoration: restoration,
            onOutcome: onOutcome,
            onError: onError
        )
    }

    @discardableResult
    public func presentSurvey(
        slug: String? = nil,
        restoration: Skyra.Restoration = .resumeInterrupted,
        onOutcome: ((SkyraResult) -> Void)? = nil,
        onError: ((Error) -> Void)? = nil
    ) -> SkyraSurveyRequest {
        let handle = SkyraSurveyRequest()
        guard let sdk else {
            Self.report(initializationError ?? SkyraIntegrationError.missingRoot, callback: onError)
            return handle
        }
        guard
            following == nil, sdk.active == nil, sdk.parkedFollowing == nil,
            sdk.screenPriorityVisit == nil, sdk.screenCandidateVisit == nil,
            sdk.pendingPresentation == nil,
            sdk.followingLifetime == nil
        else {
            Self.report(SkyraError.alreadyPresenting, callback: onError)
            return handle
        }
        guard slug != nil || sdk.configuration.organization != nil else {
            Self.report(SkyraError.missingOrganization, callback: onError)
            return handle
        }

        if let slug, !Identifiers.isValidSurveySlug(slug) {
            Self.report(SkyraError.invalidSlug, callback: onError)
            return handle
        }
        guard sdk.followingHostExpected else {
            Self.report(SkyraIntegrationError.missingFollowingHost, callback: onError)
            return handle
        }

        let lifetime = FollowingLifetime(sdk: sdk, now: sdk.followingNow)
        let pending = PendingPresentation(followsNavigation: true)
        sdk.followingLifetime = lifetime
        sdk.pendingPresentation = pending
        following = handle
        followingPending = pending
        handle.cancelAction = { [weak self, weak sdk, weak handle, weak lifetime] in
            guard
                let self, let sdk, let handle, let lifetime,
                self.following === handle, sdk.followingLifetime === lifetime
            else {
                return
            }

            lifetime.stop()
            self.followingPending?.cancel()
            sdk.cancelFollowingRequest()
            self.followingTask?.cancel()
        }
        lifetime.onInvalidate = { [weak handle] in handle?.cancel() }
        let task = Task { [weak self, sdk, handle, lifetime] in
            let outcome: Result<SkyraResult, Error>
            do {
                outcome = .success(try await sdk.presentFollowingSurvey(
                    slug: slug,
                    restoration: restoration,
                    lifetime: lifetime,
                    pending: pending
                ))
            } catch is CancellationError {
                outcome = .success(.interrupted)
            } catch {
                outcome = .failure(error)
            }
            lifetime.stop()
            lifetime.onInvalidate = nil
            if sdk.followingLifetime === lifetime {
                sdk.followingLifetime = nil
            }
            if sdk.pendingPresentation === pending {
                sdk.pendingPresentation = nil
            }
            if self?.following === handle {
                self?.following = nil
                self?.followingTask = nil
                self?.followingPending = nil
            }
            handle.cancelAction = nil
            switch outcome {
            case .success(let result):
                onOutcome?(result)
            case .failure(let error):
                Self.report(error, callback: onError)
            }
        }
        followingTask = task
        // Task execution is main-actor scheduled, so it cannot begin until this synchronous
        // method yields. Publish cancellation ownership before start can synchronously invalidate.
        lifetime.start()
        return handle
    }

    /// Deliberately reject an unfinished presentation, including one temporarily hidden.
    /// A request still preparing is interrupted; confirmed acceptance remains completed.
    public func dismissSurvey() {
        sdk?.dismissSurvey()
    }

    private var activationWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var activityObserver: InstallationActivityObserver?

    init(configuration: SkyraConfiguration, onError: ((Error) -> Void)?) {
        self.onError = onError
        do {
            sdk = try Skyra(configuration: configuration)
            initializationError = nil
        } catch {
            sdk = nil
            initializationError = error
        }
        sdk?.setSceneActive(false)
    }

    /// Internal injection keeps lifecycle tests independent of delivery and hosted-page services.
    init(sdk: Skyra) {
        self.sdk = sdk
        initializationError = nil
        onError = nil
        sdk.setSceneActive(false)
    }

    func reportInitialization() {
        guard !reportedInitialization else {
            return
        }

        reportedInitialization = true
        if let initializationError {
            Self.report(initializationError, callback: onError)
        }
    }

    /// Screen attachments interrupt on deactivation; installation-owned requests suspend instead.
    func setActive(_ active: Bool) {
        self.active = active
        sdk?.setScreenAwareSceneActive(active)
        sdk?.active?.setSuspended(!active)
        sdk?.parkedFollowing?.setSuspended(!active)
        if active {
            let waiters = activationWaiters
            activationWaiters.removeAll()
            for waiter in waiters.values {
                waiter.resume()
            }
        }
    }

    private func waitUntilActive() async throws {
        try Task.checkCancellation()
        if active {
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                activationWaiters[id] = continuation
                if Task.isCancelled {
                    activationWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
                }
            }
        }, onCancel: {
            Task { @MainActor in
                self.activationWaiters.removeValue(forKey: id)?.resume(
                    throwing: CancellationError()
                )
            }
        })
        try Task.checkCancellation()
        // Activity may have changed again before the resumed task executes.
        if !active {
            try await waitUntilActive()
        }
    }

    func observeActivity(in window: UIWindow, center: NotificationCenter = .default) {
        let scene = window.windowScene
        activityObserver = InstallationActivityObserver(
            scope: scene,
            center: center,
            initiallyActive: scene.map { $0.activationState == .foregroundActive }
                ?? (UIApplication.shared.applicationState == .active),
            onChange: { [weak self] in self?.setActive($0) },
            onDisconnect: { [weak self] in
                guard let self else {
                    return
                }

                self.setActive(false)
                self.sdk?.setPresenter(nil)
            }
        )
    }

    static func report(_ error: Error, callback: ((Error) -> Void)?) {
        #if DEBUG
        NSLog("[Skyra] %@: %@", String(describing: error), error.localizedDescription)
        #endif
        callback?(error)
    }

    deinit { followingTask?.cancel() }

    static func request(
        installation: SkyraInstallation?,
        slug: String?,
        presenter: UIViewController? = nil,
        visit: UUID? = nil,
        onOutcome: ((SkyraResult) -> Void)?,
        onError: ((Error) -> Void)?
    ) async {
        do {
            try Task.checkCancellation()
            guard let installation else {
                throw SkyraIntegrationError.missingRoot
            }

            if let error = installation.initializationError {
                throw error
            }
            guard let sdk = installation.sdk else {
                return
            }

            try await installation.waitUntilActive()
            let result: SkyraResult
            if let visit {
                result = try await sdk.presentScreenSurvey(
                    slug: slug,
                    from: presenter,
                    visit: visit
                )
            } else if let presenter {
                result = try await sdk.presentSurvey(slug: slug, from: presenter)
            } else {
                result = try await sdk.presentSurvey(slug: slug)
            }
            onOutcome?(result)
        } catch is CancellationError {
            // Departure before presentation is a normal lifecycle event.
        } catch {
            report(error, callback: onError)
        }
    }
}

/// UIKit scene notifications are delivered on the main thread. Selector delivery updates the gate
/// synchronously, before a delivery/delay continuation can allocate a popup in the background.
@MainActor
final class InstallationActivityObserver: NSObject {
    private let onChange: (Bool) -> Void
    private let center: NotificationCenter
    private let onDisconnect: () -> Void

    init(
        scope: NSObject?,
        center: NotificationCenter = .default,
        initiallyActive: Bool,
        onChange: @escaping (Bool) -> Void,
        onDisconnect: @escaping () -> Void = {}
    ) {
        self.onChange = onChange
        self.center = center
        self.onDisconnect = onDisconnect
        super.init()
        if let scope {
            center.addObserver(
                self,
                selector: #selector(activate),
                name: UIScene.didActivateNotification,
                object: scope
            )
            center.addObserver(
                self,
                selector: #selector(deactivate),
                name: UIScene.willDeactivateNotification,
                object: scope
            )
            center.addObserver(
                self,
                selector: #selector(deactivate),
                name: UIScene.didEnterBackgroundNotification,
                object: scope
            )
            center.addObserver(
                self,
                selector: #selector(disconnect),
                name: UIScene.didDisconnectNotification,
                object: scope
            )
        } else {
            // Legacy UIKit windows (and scene-less XCTest hosts) use application lifecycle only.
            center.addObserver(
                self,
                selector: #selector(activate),
                name: UIApplication.didBecomeActiveNotification,
                object: nil
            )
            center.addObserver(
                self,
                selector: #selector(deactivate),
                name: UIApplication.willResignActiveNotification,
                object: nil
            )
            center.addObserver(
                self,
                selector: #selector(deactivate),
                name: UIApplication.didEnterBackgroundNotification,
                object: nil
            )
        }
        onChange(initiallyActive)
    }

    @objc private func activate(_ notification: Notification) {
        onChange(true)
    }

    @objc private func deactivate(_ notification: Notification) {
        onChange(false)
    }

    @objc private func disconnect(_ notification: Notification) {
        onChange(false)
        onDisconnect()
    }

    deinit { center.removeObserver(self) }
}

/// Integration mistakes leave the app usable and are reported through optional callbacks and debug logs.
public enum SkyraIntegrationError: Error, LocalizedError, Equatable {
    case missingRoot
    case missingFollowingHost

    public var errorDescription: String? {
        switch self {
        case .missingRoot:
            return "Skyra survey has no root installation. Add .skyra() above this screen, or call Skyra.install(in:) for its UIKit window before attaching the survey."
        case .missingFollowingHost:
            return "Following surveys require a SkyraRootViewController UIKit root or the SwiftUI .skyra() root modifier. Screen-based Skyra.install(in:) alone does not install a following host."
        }
    }
}

@MainActor
public final class SkyraSurveyRequest {
    fileprivate var task: Task<Void, Never>?
    fileprivate var cancelAction: (() -> Void)?
    private var cancelled = false
    fileprivate init() {}
    /// Interrupt this request without recording rejection. Dropping the handle does not cancel it.
    public func cancel() {
        guard !cancelled else {
            return
        }

        cancelled = true
        cancelAction?()
        task?.cancel()
    }
}

private struct InstallationKey: EnvironmentKey {
    static let defaultValue: SkyraInstallation? = nil
}

extension EnvironmentValues {
    public var skyraInstallation: SkyraInstallation? {
        get { self[InstallationKey.self] }
        set { self[InstallationKey.self] = newValue }
    }
}

@MainActor
struct ExplicitRootModifier: ViewModifier {
    @StateObject private var installation: SkyraInstallation
    @Environment(\.scenePhase) private var scenePhase

    init(configuration: SkyraConfiguration, onError: ((Error) -> Void)?) {
        let installation = SkyraInstallation(
            configuration: configuration,
            onError: onError
        )
        _installation = StateObject(wrappedValue: installation)
        installation.sdk?.followingHostExpected = true
    }

    init(installation: SkyraInstallation) {
        _installation = StateObject(wrappedValue: installation)
        installation.sdk?.followingHostExpected = true
    }

    func body(content: Content) -> some View {
        content
            .environment(\.skyraInstallation, installation)
            .background {
                if let sdk = installation.sdk {
                    SkyraPresenter(sdk)
                }
            }
            .overlay {
                if let sdk = installation.sdk {
                    FollowingPresenter(sdk)
                }
            }
            .onAppear {
                installation.reportInitialization()
                installation.setActive(scenePhase == .active)
            }
            .onChange(of: scenePhase) { installation.setActive($0 == .active) }
    }
}

@MainActor
private final class SurveyRequestLifetime: ObservableObject {
    private var task: Task<Void, Never>?

    /// A replacement waits for cancellation/teardown of this attachment's preceding visit only.
    /// This avoids racing the SDK's single-presentation reservation on rapid reentry or slug changes.
    func run(_ operation: @escaping @MainActor () async -> Void) async {
        let previous = task
        previous?.cancel()
        let current = Task {
            await previous?.value
            guard !Task.isCancelled else {
                return
            }

            await operation()
        }
        task = current
        await withTaskCancellationHandler(operation: {
            await current.value
        }, onCancel: {
            current.cancel()
        })
    }

    deinit { task?.cancel() }
}

@MainActor
private struct ExplicitSurveyModifier: ViewModifier {
    @Environment(\.skyraInstallation) private var installation
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var lifetime = SurveyRequestLifetime()
    @State private var visit = UUID()
    let slug: String?
    let onOutcome: ((SkyraResult) -> Void)?
    let onError: ((Error) -> Void)?

    func body(content: Content) -> some View {
        content.task(id: slug) {
            // Descendant tasks can start before the root's onAppear callback.
            installation?.setActive(scenePhase == .active)
            installation?.sdk?.endScreenVisit(visit)
            let currentVisit = UUID()
            visit = currentVisit
            await lifetime.run {
                await SkyraInstallation.request(
                    installation: installation,
                    slug: slug,
                    visit: currentVisit,
                    onOutcome: onOutcome,
                    onError: onError
                )
            }
        }
        .onDisappear { installation?.sdk?.endScreenVisit(visit) }
    }
}

extension View {
    /// Install once at each window's root, above screens using `skyraSurvey`.
    /// Configuration and the root error callback are captured for that root's lifetime.
    @MainActor
    public func skyra(
        configuration: SkyraConfiguration = .init(),
        onError: ((Error) -> Void)? = nil
    ) -> some View {
        modifier(ExplicitRootModifier(configuration: configuration, onError: onError))
    }

    /// Explicitly request this survey on entry; cancel on departure or slug change. Reentry requests again.
    /// Cancellation before display is silent; an interrupted popup reports `.interrupted`.
    /// An inactive entry waits for activation. Once attempted, scene activation alone does not retry it.
    @MainActor
    public func skyraSurvey(
        _ slug: String? = nil,
        onOutcome: ((SkyraResult) -> Void)? = nil,
        onError: ((Error) -> Void)? = nil
    ) -> some View {
        modifier(ExplicitSurveyModifier(slug: slug, onOutcome: onOutcome, onError: onError))
    }

    @MainActor
    public func skyraSurvey(
        _ slug: String,
        onOutcome: ((SkyraResult) -> Void)? = nil,
        onError: ((Error) -> Void)? = nil
    ) -> some View {
        skyraSurvey(Optional(slug), onOutcome: onOutcome, onError: onError)
    }
}

private var installationAssociation: UInt8 = 0

extension Skyra {
    func setScreenAwareSceneActive(_ active: Bool) {
        #if canImport(UIKit)
        if screenCandidateVisit != nil || screenPriorityVisit != nil {
            sceneActive = active
            followingLifetime?.setActive(active)
            screenCandidateLifetime?.setActive(active)
            if !active, self.active?.ownershipRole == .screenVisit {
                self.active?.interrupt()
            }
            if active {
                screenCandidateController?.revealIfReady()
            }
            return
        }
        #endif
        setSceneActive(active)
    }

    func setPrioritySceneActive(_ active: Bool) {
        self.active?.setSuspended(!active)
        parkedFollowing?.setSuspended(!active)
    }

    /// The window retains this installation. Repeated calls return its original configuration/SDK.
    /// Install after assigning the window's scene. Scene-less windows use application activity.
    @discardableResult
    public static func install(
        in window: UIWindow,
        configuration: SkyraConfiguration = .init(),
        onError: ((Error) -> Void)? = nil
    ) -> SkyraInstallation {
        if
            let existing = objc_getAssociatedObject(
                window,
                &installationAssociation
            ) as? SkyraInstallation
        {
            if
                let sdk = existing.sdk,
                let root = window.rootViewController as? SkyraRootViewController
            {
                sdk.setPresenter(root.content)
                root.bind(sdk: sdk, window: window)
            }
            return existing
        }
        let installation = SkyraInstallation(configuration: configuration, onError: onError)
        objc_setAssociatedObject(
            window,
            &installationAssociation,
            installation,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        if
            let sdk = installation.sdk,
            let root = window.rootViewController as? SkyraRootViewController
        {
            sdk.setPresenter(root.content)
            root.bind(sdk: sdk, window: window)
        } else {
            installation.sdk?.setPresenter(window.rootViewController)
        }
        installation.observeActivity(in: window)
        installation.reportInitialization()
        return installation
    }
}

/// A screen retains this child automatically. Its appearance explicitly requests a survey;
/// disappearance cancels only that request. Keep the returned handle only to detach early.
@MainActor
public final class SkyraSurveyAttachment: UIViewController {
    private let slug: String?
    private let onOutcome: ((SkyraResult) -> Void)?
    private let onError: ((Error) -> Void)?
    private var request: Task<Void, Never>?
    private weak var visitSDK: Skyra?
    private let lifetime = SurveyRequestLifetime()
    private var visit = UUID()

    init(slug: String?, onOutcome: ((SkyraResult) -> Void)?, onError: ((Error) -> Void)?) {
        self.slug = slug
        self.onOutcome = onOutcome
        self.onError = onError
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("Use UIViewController.skyraSurvey")
    }

    deinit { request?.cancel() }

    public override func loadView() {
        view = UIView()
        view.isUserInteractionEnabled = false
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard let screen = parent else {
            return
        }

        // A new appearance is a new visit even if the preceding outcome callback has fired
        // before its task has finished unwinding. The shared lifetime serializes teardown.
        request?.cancel()
        visitSDK?.endScreenVisit(visit)
        var installation: SkyraInstallation?
        if let window = screen.viewIfLoaded?.window {
            installation = objc_getAssociatedObject(
                window,
                &installationAssociation
            ) as? SkyraInstallation
        }
        let slug = slug
        let onOutcome = onOutcome
        let onError = onError
        let lifetime = lifetime
        let visit = UUID()
        self.visit = visit
        visitSDK = installation?.sdk
        request = Task { [weak self] in
            await lifetime.run {
                await SkyraInstallation.request(
                    installation: installation,
                    slug: slug,
                    presenter: screen,
                    visit: visit,
                    onOutcome: onOutcome,
                    onError: onError
                )
            }
            if self?.visit == visit {
                self?.request = nil
            }
        }
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        request?.cancel()
        visitSDK?.endScreenVisit(visit)
        visitSDK = nil
        request = nil
    }

    /// Permanently remove this request's lifecycle attachment without recording rejection.
    public func detach() {
        request?.cancel()
        request = nil
        visitSDK?.endScreenVisit(visit)
        visitSDK = nil
        willMove(toParent: nil)
        viewIfLoaded?.removeFromSuperview()
        removeFromParent()
    }
}

extension UIViewController {
    /// Attach once, normally in viewDidLoad. Each appearance requests the supplied slug;
    /// each departure cancels it. Requires `Skyra.install(in:)` for this screen's window.
    /// Inactive entry waits for activation; foregrounding alone does not replay an attempted request.
    @discardableResult
    public func skyraSurvey(
        _ slug: String? = nil,
        onOutcome: ((SkyraResult) -> Void)? = nil,
        onError: ((Error) -> Void)? = nil
    ) -> SkyraSurveyAttachment {
        loadViewIfNeeded()
        let attachment = SkyraSurveyAttachment(slug: slug, onOutcome: onOutcome, onError: onError)
        addChild(attachment)
        view.addSubview(attachment.view)
        attachment.didMove(toParent: self)
        return attachment
    }

    @MainActor
    @discardableResult
    public func skyraSurvey(
        _ slug: String,
        onOutcome: ((SkyraResult) -> Void)? = nil,
        onError: ((Error) -> Void)? = nil
    ) -> SkyraSurveyAttachment {
        skyraSurvey(Optional(slug), onOutcome: onOutcome, onError: onError)
    }
}
#endif
