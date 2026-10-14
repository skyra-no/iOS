// Turns presentSurvey calls into one attached SurveyController and waits for its final result.
// Read this file first to follow the explicit-presentation flow; popup behavior is in SurveyController.swift.
#if canImport(UIKit)
import UIKit

/// Holds cancellable delivery lookup and display delay before there is a popup to close.
/// A class lets asynchronous work and visibility callbacks share the pending request's continuations.
@MainActor
final class PendingPresentation {
    let followsNavigation: Bool
    var task: Task<Void, Never>?
    var decisionContinuation: CheckedContinuation<SkyraSurveyDecision, Error>?
    var continuation: CheckedContinuation<PresentationPolicy?, Error>?
    var presenterContinuation: CheckedContinuation<UIViewController, Error>?
    private var delayContinuation: CheckedContinuation<Void, Error>?
    private(set) var invalidated = false

    init(followsNavigation: Bool = false) {
        self.followsNavigation = followsNavigation
    }

    /// Called when the host or scene changes. Cancels the lookup and prevents a late reply opening a popup.
    func cancel() {
        invalidated = true
        finishPresenter(.failure(CancellationError()))
        finishDecision(.failure(CancellationError()))
        finish(.failure(CancellationError()))
        finishDelay(.failure(CancellationError()))
    }

    func decide(sdk: Skyra, slug: String?) async throws -> SkyraSurveyDecision {
        try Task.checkCancellation()
        guard !invalidated else {
            throw CancellationError()
        }

        let decision = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                decisionContinuation = continuation
                task = Task { [weak self, sdk] in
                    do {
                        self?.finishDecision(
                            .success(try await sdk.resolvePresentationDecision(slug: slug))
                        )
                    } catch {
                        self?.finishDecision(.failure(error))
                    }
                }
                if Task.isCancelled {
                    finishDecision(.failure(CancellationError()))
                }
            }
        }, onCancel: {
            Task { @MainActor [weak self] in self?.finishDecision(.failure(CancellationError())) }
        })
        try Task.checkCancellation()
        guard !invalidated else {
            throw CancellationError()
        }

        return decision
    }

    func finishDecision(_ result: Result<SkyraSurveyDecision, Error>) {
        guard let continuation = decisionContinuation else {
            return
        }

        decisionContinuation = nil
        task?.cancel()
        task = nil
        continuation.resume(with: result)
    }

    /// Host registration and cancellation race to resolve readiness exactly once.
    func finishPresenter(_ result: Result<UIViewController, Error>) {
        let continuation = presenterContinuation
        presenterContinuation = nil
        continuation?.resume(with: result)
    }

    func waitForPresenter() async throws -> UIViewController {
        try Task.checkCancellation()
        if invalidated {
            throw CancellationError()
        }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                presenterContinuation = continuation
                if Task.isCancelled {
                    finishPresenter(.failure(CancellationError()))
                }
            }
        }, onCancel: {
            Task { @MainActor [weak self] in self?.finishPresenter(.failure(CancellationError())) }
        })
    }

    /// Wait before session allocation. Navigation can resolve this wait even if an injected sleeper ignores cancellation.
    func wait(milliseconds: Double, sleep: @escaping (UInt64) async throws -> Void) async throws {
        try Task.checkCancellation()
        if invalidated {
            throw CancellationError()
        }
        if milliseconds == 0 {
            return
        }
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                delayContinuation = continuation
                task = Task {
                    do {
                        try await sleep(UInt64(milliseconds * 1_000_000))
                        finishDelay(.success(()))
                    } catch {
                        finishDelay(.failure(error))
                    }
                }
            }
        }, onCancel: {
            Task { @MainActor in self.cancel() }
        })
        try Task.checkCancellation()
        if invalidated {
            throw CancellationError()
        }
    }

    /// Clear the delay continuation before resuming, making late timer replies harmless.
    private func finishDelay(_ result: Result<Void, Error>) {
        guard let continuation = delayContinuation else {
            return
        }

        delayContinuation = nil
        task?.cancel()
        task = nil
        continuation.resume(with: result)
    }

    /// Resumes the presentSurvey call with the lookup's result or cancellation, once.
    /// Clearing the continuation before resuming prevents a late network reply from resuming it again.
    func finish(_ result: Result<PresentationPolicy?, Error>) {
        guard let continuation else {
            return
        }

        self.continuation = nil
        task?.cancel()
        task = nil
        continuation.resume(with: result)
    }
}

@MainActor
private final class ScreenAliasWaiter {
    private weak var controller: SurveyController?
    private var observerID: UUID?
    private var continuation: CheckedContinuation<SkyraResult, Error>?

    init(controller: SurveyController) {
        self.controller = controller
    }

    func value() async throws -> SkyraResult {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                observerID = controller?.observeFinish { [weak self] result in
                    self?.finish(result)
                }
                if Task.isCancelled {
                    cancel()
                }
            }
        }, onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        })
    }

    private func finish(_ result: Result<SkyraResult, Error>) {
        guard let continuation else {
            return
        }

        self.continuation = nil
        if let observerID {
            controller?.removeFinishObserver(observerID)
        }
        observerID = nil
        continuation.resume(with: result)
    }

    private func cancel() {
        guard let continuation else {
            return
        }

        self.continuation = nil
        if let observerID {
            controller?.removeFinishObserver(observerID)
        }
        observerID = nil
        continuation.resume(throwing: CancellationError())
    }
}

@MainActor
final class ScreenVisitLifetime {
    private weak var sdk: Skyra?
    private weak var host: UIViewController?
    private let now: () -> TimeInterval
    private let sleep: (UInt64) async throws -> Void
    private var sceneActive: Bool
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var delayContinuation: CheckedContinuation<Void, Error>?
    private var delayTask: Task<Void, Never>?
    private var delayGeneration: UUID?
    private var remaining: TimeInterval = 0
    private var lastEligibleTime: TimeInterval
    private var cancelled = false

    init(sdk: Skyra, host: UIViewController) {
        self.sdk = sdk
        self.host = host
        now = sdk.followingNow
        sleep = sdk.waitForDelay
        sceneActive = sdk.sceneActive
        lastEligibleTime = now()
    }

    var isAvailable: Bool {
        !cancelled && sceneActive && sdk?.sceneActive == true && host?.viewIfLoaded?.window != nil
    }

    func setActive(_ active: Bool) {
        accountElapsed()
        sceneActive = active
        if active, isAvailable {
            let pending = waiters.values
            waiters.removeAll()
            pending.forEach { $0.resume() }
            scheduleDelay()
        } else {
            delayGeneration = nil
            delayTask?.cancel()
            delayTask = nil
        }
    }

    func waitUntilAvailable() async throws {
        while true {
            try Task.checkCancellation()
            guard !cancelled else {
                throw CancellationError()
            }

            if isAvailable {
                return
            }
            let id = UUID()
            try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    waiters[id] = continuation
                    if Task.isCancelled {
                        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
                    }
                }
            }, onCancel: {
                Task { @MainActor [weak self] in
                    self?.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
                }
            })
        }
    }

    func wait(milliseconds: Double) async throws {
        try await waitUntilAvailable()
        guard milliseconds > 0 else {
            return
        }

        remaining = milliseconds / 1_000
        lastEligibleTime = now()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                delayContinuation = continuation
                scheduleDelay()
                if Task.isCancelled {
                    cancelDelay()
                }
            }
        }, onCancel: {
            Task { @MainActor [weak self] in self?.cancelDelay() }
        })
        try await waitUntilAvailable()
    }

    func cancel() {
        cancelled = true
        delayGeneration = nil
        delayTask?.cancel()
        delayTask = nil
        let waiters = waiters.values
        self.waiters.removeAll()
        waiters.forEach { $0.resume(throwing: CancellationError()) }
        cancelDelay()
    }

    private func accountElapsed() {
        let current = now()
        if isAvailable, delayContinuation != nil {
            remaining = max(0, remaining - max(0, current - lastEligibleTime))
        }
        lastEligibleTime = current
        if isAvailable, remaining <= 0 {
            finishDelay()
        }
    }

    private func scheduleDelay() {
        guard isAvailable, delayContinuation != nil, delayTask == nil else {
            return
        }

        accountElapsed()
        guard remaining > 0 else {
            finishDelay()
            return
        }

        let duration = UInt64(min(remaining, Double(UInt64.max) / 1_000_000_000) * 1_000_000_000)
        let sleep = sleep
        let generation = UUID()
        delayGeneration = generation
        delayTask = Task { [weak self] in
            do {
                try await sleep(duration)
            } catch {
                guard let self, self.delayGeneration == generation, self.isAvailable else {
                    return
                }

                self.delayGeneration = nil
                self.delayTask = nil
                let continuation = self.delayContinuation
                self.delayContinuation = nil
                continuation?.resume(throwing: error)
                return
            }
            guard let self, self.delayGeneration == generation, self.isAvailable else {
                return
            }

            self.delayGeneration = nil
            self.delayTask = nil
            self.accountElapsed()
            self.scheduleDelay()
        }
    }

    private func finishDelay() {
        guard let continuation = delayContinuation else {
            return
        }

        delayContinuation = nil
        delayGeneration = nil
        delayTask?.cancel()
        delayTask = nil
        continuation.resume()
    }

    private func cancelDelay() {
        guard let continuation = delayContinuation else {
            return
        }

        delayContinuation = nil
        delayGeneration = nil
        delayTask?.cancel()
        delayTask = nil
        continuation.resume(throwing: CancellationError())
    }
}

extension Skyra {
    func awaitScreenAlias(_ controller: SurveyController, visit: UUID) async throws -> SkyraResult {
        screenPriorityVisit = visit
        screenPriorityAliasesFollowing = true
        screenCandidateVisit = nil
        screenCandidatePending = nil
        return try await ScreenAliasWaiter(controller: controller).value()
    }

    /// Ends one lifecycle-owned screen visit. A completed popup does not release its screen lease.
    func endScreenVisit(_ visit: UUID) {
        if screenCandidateVisit == visit {
            screenCandidateVisit = nil
            screenCandidatePending?.cancel()
            screenCandidatePending = nil
            screenCandidateLifetime?.cancel()
            screenCandidateLifetime = nil
            screenCandidateController?.cancelBeforeReveal()
        }
        guard screenPriorityVisit == visit else {
            return
        }

        screenPriorityVisit = nil
        if screenPriorityAliasesFollowing {
            screenPriorityAliasesFollowing = false
            return
        }
        if let current = active, current !== parkedFollowing {
            current.interrupt()
        }
        if let parked = parkedFollowing {
            parkedFollowing = nil
            if !parked.bridge.finished {
                active = parked
                parked.setSuspended(!sceneActive)
            }
        }
    }

    func presentFollowingSurvey(
        slug: String?,
        restoration: Restoration,
        lifetime: FollowingLifetime,
        pending: PendingPresentation
    ) async throws -> SkyraResult {
        guard followingHostExpected else {
            throw SkyraIntegrationError.missingFollowingHost
        }

        return try await presentSurvey(
            slug: slug,
            from: nil,
            restoration: restoration,
            reservedPending: pending,
            following: lifetime
        )
    }

    func cancelFollowingRequest() {
        pendingPresentation?.cancel()
        if let parkedFollowing {
            parkedFollowing.interrupt()
        } else if active?.ownershipRole == .installationFollowing {
            active?.interrupt()
        }
    }

    /// Automatic selection calls this before presentation when an app sheet may still be dismissing.
    /// SwiftUI can clear its binding before UIKit finishes the transition; wait for the actual host.
    func waitForHostTransition(from presenter: UIViewController) async {
        var host = presenter
        while let parent = host.parent {
            host = parent
        }
        guard
            let presented = host.presentedViewController,
            let transition = presented.transitionCoordinator
        else {
            return
        }

        await withCheckedContinuation { continuation in
            var resume: (() -> Void)? = { continuation.resume() }
            let finish = {
                let callback = resume
                resume = nil
                callback?()
            }
            if
                !transition.animate(alongsideTransition: nil, completion: { _ in
                    finish()
                })
            {
                finish()
            }
        }
    }

    /// The app or SwiftUI adapter supplies the controller in its own scene that can host the popup.
    /// Changing hosts cancels pending work so a stale lookup cannot present into the previous scene.
    public func setPresenter(_ controller: UIViewController?) {
        if let pending = screenCandidatePending, pending.presenterContinuation != nil {
            presenter = controller
            observePresenterDisconnect(controller)
            if let controller {
                pending.finishPresenter(.success(controller))
            } else {
                pending.finishPresenter(.failure(CancellationError()))
            }
            return
        }
        if let pending = pendingPresentation, pending.presenterContinuation != nil {
            presenter = controller
            observePresenterDisconnect(controller)
            if let controller {
                pending.finishPresenter(.success(controller))
            } else {
                pending.cancel()
            }
            return
        }
        if presenter !== controller {
            if screenCandidateVisit != nil {
                screenCandidateVisit = nil
                screenCandidatePending?.cancel()
                screenCandidateLifetime?.cancel()
                screenCandidateController?.interrupt()
                screenCandidatePending = nil
                screenCandidateLifetime = nil
                screenCandidateController = nil
            }
            if screenPriorityVisit != nil {
                screenPriorityVisit = nil
                screenPriorityAliasesFollowing = false
                let visible = active
                let parked = parkedFollowing
                active = nil
                parkedFollowing = nil
                visible?.interrupt()
                parked?.interrupt()
            }
            if pendingPresentation?.followsNavigation != true {
                pendingPresentation?.cancel()
            }
            if active?.ownershipRole != .installationFollowing {
                active?.interrupt()
            }
        }
        presenter = controller
        observePresenterDisconnect(controller)
    }

    private func observePresenterDisconnect(_ controller: UIViewController?) {
        if let presenterDisconnectObserver {
            NotificationCenter.default.removeObserver(presenterDisconnectObserver)
            self.presenterDisconnectObserver = nil
        }
        if let scene = controller?.viewIfLoaded?.window?.windowScene {
            presenterDisconnectObserver = NotificationCenter.default.addObserver(
                forName: UIScene.didDisconnectNotification,
                object: scene,
                queue: .main
            ) { [weak self, weak controller] _ in
                Task { @MainActor in
                    guard let self, self.presenter === controller else {
                        return
                    }

                    // This SDK belongs to the disconnected scene. Close its activity gate before
                    // releasing the host so pending and following work cannot reserve stale UI.
                    self.setSceneActive(false)
                    self.screenCandidatePending?.cancel()
                    self.screenCandidateLifetime?.cancel()
                    self.screenCandidateController?.interrupt()
                    self.screenCandidateVisit = nil
                    self.screenCandidatePending = nil
                    self.screenCandidateLifetime = nil
                    if self.screenPriorityVisit != nil {
                        self.screenPriorityVisit = nil
                        self.screenPriorityAliasesFollowing = false
                        self.active?.interrupt()
                        self.parkedFollowing?.interrupt()
                        self.parkedFollowing = nil
                    }
                    if self.pendingPresentation?.followsNavigation != true {
                        self.pendingPresentation?.cancel()
                    }
                    if self.active?.ownershipRole != .installationFollowing {
                        self.active?.interrupt()
                    }
                    self.setPresenter(nil)
                }
            }
        }
    }

    /// App entry point using the host previously supplied through setPresenter or SkyraPresenter.
    /// Waits for host registration when called before SkyraPresenter appears. Cancelling the calling
    /// task (for example, a SwiftUI screen's .task) also cancels this wait without recording rejection.
    /// Returns when the survey is not shown or its popup has finished closing.
    public func presentSurvey(
        slug: String,
        restoration: Restoration = .resumeInterrupted
    ) async throws -> SkyraResult {
        try await presentSurvey(slug: Optional(slug), restoration: restoration)
    }

    public func presentSurvey(
        slug: String? = nil,
        restoration: Restoration = .resumeInterrupted
    ) async throws -> SkyraResult {
        try Task.checkCancellation()
        guard
            active == nil, pendingPresentation == nil, followingLifetime == nil,
            screenPriorityVisit == nil, screenCandidateVisit == nil
        else {
            throw SkyraError.alreadyPresenting
        }
        guard slug != nil || configuration.organization != nil else {
            throw SkyraError.missingOrganization
        }

        if let slug, !Identifiers.isValidSurveySlug(slug) {
            throw SkyraError.invalidSlug
        }

        let pending = PendingPresentation()
        pendingPresentation = pending
        defer {
            if pendingPresentation === pending {
                pendingPresentation = nil
            }
        }
        let host: UIViewController?
        if let presenter {
            host = presenter
        } else {
            guard sceneActive else {
                throw SkyraError.presenterUnavailable
            }

            host = try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    pending.presenterContinuation = continuation
                    if Task.isCancelled {
                        pending.cancel()
                    }
                }
            }, onCancel: {
                Task { @MainActor in pending.cancel() }
            })
        }
        return try await presentSurvey(
            slug: slug,
            from: host,
            restoration: restoration,
            reservedPending: pending
        )
    }

    /// UIKit entry point: supply the screen whose visibility owns this particular request.
    /// Direct requests use the same decision and storage rules as screen and following requests.
    public func presentSurvey(
        slug: String,
        from presenter: UIViewController,
        restoration: Restoration = .resumeInterrupted
    ) async throws -> SkyraResult {
        try await presentSurvey(slug: Optional(slug), from: presenter, restoration: restoration)
    }

    public func presentSurvey(
        slug: String? = nil,
        from presenter: UIViewController,
        restoration: Restoration = .resumeInterrupted
    ) async throws -> SkyraResult {
        try await presentSurvey(
            slug: slug,
            from: presenter,
            restoration: restoration,
            screenVisit: nil
        )
    }

    /// Internal entry reserved for lifecycle-owned UIKit and SwiftUI screen visits.
    func presentScreenSurvey(
        slug: String?,
        from presenter: UIViewController?,
        visit: UUID
    ) async throws -> SkyraResult {
        try await presentSurvey(
            slug: slug,
            from: presenter,
            restoration: .resumeInterrupted,
            screenVisit: visit
        )
    }

    /// Shared presentation flow: reserve a slot, check policy, prepare identity, attach the popup,
    /// and suspend until SurveyController calls onFinish. All presentation modes meet here.
    func presentSurvey(
        slug: String?,
        from presenter: UIViewController?,
        restoration: Restoration,
        reservedPending: PendingPresentation? = nil,
        following: FollowingLifetime? = nil,
        screenVisit: UUID? = nil
    ) async throws -> SkyraResult {
        // Reserve ownership before awaiting selection or delivery: a second request must not race it.
        try Task.checkCancellation()
        guard
            (active == nil || (screenVisit != nil && active?.ownershipRole == .installationFollowing
                    && parkedFollowing == nil)),
            screenPriorityVisit == nil, screenCandidateVisit == nil,
            screenVisit == nil
            ? pendingPresentation === reservedPending && followingLifetime === following
            : reservedPending == nil && following == nil && pendingPresentation == nil
            && screenCandidatePending == nil
        else {
            throw SkyraError.alreadyPresenting
        }

        let pending = reservedPending ?? PendingPresentation(
            followsNavigation: following != nil || screenVisit != nil
        )
        if let screenVisit {
            screenCandidateVisit = screenVisit
            screenCandidatePending = pending
        } else {
            pendingPresentation = pending
        }
        let lifetime = PresentationLifetime()
        defer {
            lifetime.detach()
            if screenVisit != nil, screenCandidatePending === pending {
                screenCandidatePending = nil
                screenCandidateLifetime?.cancel()
                screenCandidateLifetime = nil
            } else if pendingPresentation === pending {
                pendingPresentation = nil
            }
            if
                screenVisit != nil,
                screenCandidateVisit == screenVisit
            {
                screenCandidateVisit = nil
            }
        }
        var host: UIViewController?
        var requestPresenter = presenter ?? (screenVisit == nil ? nil : self.presenter)
        if requestPresenter == nil, screenVisit != nil {
            requestPresenter = try await pending.waitForPresenter()
        }
        if following == nil {
            guard let requestPresenter else {
                throw SkyraError.presenterUnavailable
            }
            guard
                requestPresenter.viewIfLoaded?.window != nil,
                requestPresenter.presentedViewController == nil,
                !requestPresenter.isBeingDismissed
            else {
                throw SkyraError.presenterUnavailable
            }

            host = requestPresenter
            while let parent = host?.parent {
                host = parent
            }
            guard let rootHost = host, rootHost.presentedViewController == nil else {
                throw SkyraError.presenterUnavailable
            }
        } else if !followingHostExpected {
            throw SkyraIntegrationError.missingFollowingHost
        }
        if following == nil, screenVisit == nil, let presenter {
            // Resolve standard containers to their visible screen, rather than watching the root.
            var owner = presenter
            while true {
                if
                    let navigation = owner as? UINavigationController,
                    let visible = navigation.visibleViewController
                {
                    owner = visible
                } else if
                    let tabs = owner as? UITabBarController,
                    let selected = tabs.selectedViewController
                {
                    owner = selected
                } else {
                    break
                }
            }
            lifetime.onDisappear = { [weak self] in
                pending.cancel()
                if let screenVisit {
                    self?.endScreenVisit(screenVisit)
                }
            }
            lifetime.attach(to: owner)
        }
        if
            let screenVisit,
            let current = active, current.ownershipRole == .installationFollowing,
            let requested = slug, current.bridge.slug == requested
        {
            // Same-slug screen ownership aliases the existing live request; never prepare a second
            // session, WebView, or native history record for that slug.
            return try await awaitScreenAlias(current, visit: screenVisit)
        }
        let decision = try await pending.decide(sdk: self, slug: slug)
        guard !pending.invalidated else {
            throw CancellationError()
        }
        guard case .present(let resolvedSlug, let decidedDelay) = decision else {
            if case .notShown(let reason) = decision {
                return .notShown(reason: reason)
            }
            throw SkyraError.invalidConfiguration
        }

        let slug = resolvedSlug
        if
            let screenVisit, let current = active, current.ownershipRole == .installationFollowing,
            current.bridge.slug == slug
        {
            return try await awaitScreenAlias(current, visit: screenVisit)
        }

        if following == nil {
            guard
                let requestPresenter, requestPresenter.viewIfLoaded?.window != nil,
                requestPresenter.presentedViewController == nil, !requestPresenter.isBeingDismissed,
                host?.presentedViewController == nil
            else {
                throw SkyraError.presenterUnavailable
            }
        }

        try Task.checkCancellation()
        if pending.invalidated {
            throw CancellationError()
        }
        let history = try store.history(slug: slug)

        if let following {
            try await following.waitUntilAvailable()
            guard
                sceneActive, let registered = followingHost,
                registered.isValid, registered.isAvailable,
                let controller = registered.controller
            else {
                throw CancellationError()
            }

            host = controller
        } else if let screenVisit {
            guard let requestPresenter else {
                throw SkyraError.presenterUnavailable
            }

            let visitLifetime = ScreenVisitLifetime(sdk: self, host: requestPresenter)
            screenCandidateLifetime = visitLifetime
            try await visitLifetime.waitUntilAvailable()
            host = requestPresenter
        } else {
            guard
                let requestPresenter, requestPresenter.viewIfLoaded?.window != nil,
                requestPresenter.presentedViewController == nil, !requestPresenter.isBeingDismissed,
                host?.presentedViewController == nil, sceneActive
            else {
                throw SkyraError.presenterUnavailable
            }
        }

        // Web skips initialDelay for existing Capture. A fresh eligible attempt waits before SessionInit.
        if history?.status != .capture {
            if let following {
                try await following.wait(milliseconds: decidedDelay)
            } else if let screenVisit {
                guard
                    let visitLifetime = screenCandidateLifetime,
                    screenCandidateVisit == screenVisit
                else {
                    throw CancellationError()
                }

                try await visitLifetime.wait(milliseconds: decidedDelay)
            } else {
                try await pending.wait(
                    milliseconds: decidedDelay,
                    sleep: waitForDelay
                )
            }
        }
        try await following?.waitUntilAvailable()
        if let screenVisit, following == nil {
            guard
                let visitLifetime = screenCandidateLifetime,
                screenCandidateVisit == screenVisit
            else {
                throw CancellationError()
            }

            try await visitLifetime.waitUntilAvailable()
        }
        try Task.checkCancellation()
        if pending.invalidated {
            throw CancellationError()
        }
        if let following {
            guard
                sceneActive, let registered = followingHost,
                registered.isValid, registered.isAvailable,
                let controller = registered.controller
            else {
                throw CancellationError()
            }

            host = controller
        } else {
            guard
                let requestPresenter, requestPresenter.viewIfLoaded?.window != nil,
                requestPresenter.presentedViewController == nil, !requestPresenter.isBeingDismissed,
                host?.presentedViewController == nil, sceneActive
            else {
                throw SkyraError.presenterUnavailable
            }
        }
        guard let host else {
            throw SkyraError.presenterUnavailable
        }

        // Give the hosted page native identity and any resumable progress before it renders.
        let identity: (String, String, SkyraSavedState?)
        do {
            identity = try store.prepare(slug: slug, resume: restoration == .resumeInterrupted)
        } catch {
            throw SkyraError.storageFailure
        }
        let initialization = Initialization(
            visitorId: identity.0,
            sessionId: identity.1,
            language: configuration.language,
            device: UIDevice.current.userInterfaceIdiom == .pad ? "tablet" : "mobile",
            traits: configuration.traits,
            savedState: identity.2,
            textScale: SurveyController.textScale(for: host.traitCollection)
        )
        let json: String
        do {
            json = try initialization.json()
        } catch {
            throw SkyraError.invalidConfiguration
        }
        let controller = SurveyController(
            slug: slug,
            configuration: configuration,
            store: store,
            visitor: identity.0,
            session: identity.1,
            initialization: json,
            loadHostedPage: loadHostedPage
        )
        controller.followsNavigation = following != nil || screenVisit != nil
        controller.ownershipRole = following != nil
            ? .installationFollowing
            : (screenVisit != nil ? .screenVisit : .manual)
        if following == nil, screenVisit == nil {
            lifetime.onDisappear = { [weak controller] in controller?.interrupt() }
        }
        if let screenVisit {
            screenCandidateController = controller
            controller.setSuspended(true)
            controller.onWillReveal = { [weak self, weak controller] in
                guard
                    let self, let controller,
                    self.screenCandidateVisit == screenVisit,
                    self.screenCandidateController === controller,
                    self.sceneActive,
                    self.screenCandidateLifetime?.isAvailable == true
                else {
                    return false
                }

                if let current = self.active, current.ownershipRole == .installationFollowing {
                    guard self.parkedFollowing == nil else {
                        return false
                    }

                    self.parkedFollowing = current
                    current.setSuspended(true)
                } else if self.active != nil {
                    return false
                }
                self.active = controller
                self.screenPriorityVisit = screenVisit
                self.screenCandidateController = nil
                self.screenCandidateVisit = nil
                self.screenCandidatePending = nil
                self.screenCandidateLifetime = nil
                controller.setSuspended(false)
                return true
            }
        } else {
            active = controller
        }
        if let screenVisit {
            if screenCandidatePending === pending {
                screenCandidatePending = nil
            }
        } else {
            pendingPresentation = nil
        }

        // Attach a floating child view, then wait for its one final result, including exit animation.
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                controller.onFinish = { [weak self, weak controller] result in
                    if self?.active === controller {
                        self?.active = nil
                        if self?.screenPriorityVisit != nil {
                            // The screen visit, not the popup, owns the lease. Keep A parked.
                        } else if let parked = self?.parkedFollowing {
                            self?.parkedFollowing = nil
                            self?.active = parked
                            parked.setSuspended(!(self?.sceneActive ?? false))
                        }
                    } else if self?.screenCandidateController === controller {
                        self?.screenCandidateController = nil
                        self?.screenCandidateVisit = nil
                        self?.screenCandidateLifetime?.cancel()
                        self?.screenCandidateLifetime = nil
                        self?.screenCandidatePending = nil
                    } else if self?.parkedFollowing === controller {
                        self?.parkedFollowing = nil
                    }
                    continuation.resume(with: result)
                }
                if Task.isCancelled {
                    controller.cancel()
                    return
                }
                host.addChild(controller)
                controller.view.translatesAutoresizingMaskIntoConstraints = false
                host.view.addSubview(controller.view)
                NSLayoutConstraint.activate([
                    controller.view.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
                    controller.view.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
                    controller.view.topAnchor.constraint(equalTo: host.view.topAnchor),
                    controller.view.bottomAnchor.constraint(equalTo: host.view.bottomAnchor),
                ])
                controller.didMove(toParent: host)
                following?.refresh()
            }
        }, onCancel: {
            Task { @MainActor [weak controller] in controller?.cancel() }
        })
    }

    /// App-requested close. Cancels an outstanding lookup or asks the visible controller to reject.
    /// Rejection clears resumable progress; it cannot downgrade answers the page already accepted.
    public func dismissSurvey() {
        if screenCandidateVisit != nil {
            screenCandidatePending?.cancel()
            screenCandidateLifetime?.cancel()
            screenCandidateController?.cancelBeforeReveal()
            return
        }
        if screenPriorityVisit != nil, active == nil {
            // A terminal B popup leaves a screen-visit lease, not a dismissible A popup.
            return
        }
        if active == nil {
            followingLifetime?.invalidate()
        }
        pendingPresentation?.cancel()
        active?.reject()
    }
}
#endif
