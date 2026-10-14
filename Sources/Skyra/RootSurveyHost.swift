// Explicit UIKit and SwiftUI hosts for navigation-following survey popups.
#if canImport(UIKit)
import SwiftUI
import UIKit
import ObjectiveC

/// An opt-in root container for apps that want installation-owned surveys to survive navigation.
/// Wrap the app's existing root controller before calling `Skyra.install(in:)`.
@MainActor
public final class SkyraRootViewController: UIViewController {
    public let content: UIViewController
    private weak var boundSDK: Skyra?
    private var followingHost: FollowingHost?

    public init(content: UIViewController) {
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Use SkyraRootViewController(content:)")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        addChild(content)
        content.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content.view)
        NSLayoutConstraint.activate([
            content.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.view.topAnchor.constraint(equalTo: view.topAnchor),
            content.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        content.didMove(toParent: self)
    }

    public override func loadView() {
        view = FollowingRootView { [weak self] in self?.followingHost?.refresh() }
    }

    /// Binds the installation to this explicit root, even if the window is not visible yet.
    func bind(sdk: Skyra, window: UIWindow) {
        boundSDK = sdk
        let host = sdk.registerFollowingHost(self, in: window)
        followingHost = host
    }

    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let boundSDK, let window = viewIfLoaded?.window {
            bind(sdk: boundSDK, window: window)
        }
        followingHost?.refresh()
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        followingHost?.refresh()
    }

    public override var childForStatusBarStyle: UIViewController? {
        content
    }

    public override var childForStatusBarHidden: UIViewController? {
        content
    }

    public override var childForHomeIndicatorAutoHidden: UIViewController? {
        content
    }

    public override var childForScreenEdgesDeferringSystemGestures: UIViewController? {
        content
    }

    public override var shouldAutorotate: Bool {
        content.shouldAutorotate
    }

    public override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        content.supportedInterfaceOrientations
    }

    public override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        content.preferredInterfaceOrientationForPresentation
    }
}

@MainActor
final class FollowingHost: NSObject {
    weak var controller: UIViewController?
    weak var window: UIWindow?
    weak var installedRoot: UIViewController?
    fileprivate weak var sentinel: FollowingWindowSentinel?
    private weak var sdk: Skyra?
    private let center: NotificationCenter
    private(set) var isValid = true
    var onChange: (() -> Void)?

    init(
        sdk: Skyra,
        controller: UIViewController,
        window: UIWindow,
        scope: NSObject? = nil,
        center: NotificationCenter = .default
    ) {
        self.sdk = sdk
        self.controller = controller
        self.window = window
        self.center = center
        installedRoot = window.rootViewController
        super.init()
        let sentinel = FollowingWindowSentinel(host: self)
        self.sentinel = sentinel
        objc_setAssociatedObject(
            window,
            &followingWindowSentinelKey,
            sentinel,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        center.addObserver(
            self,
            selector: #selector(windowVisibilityChanged(_:)),
            name: UIWindow.didBecomeVisibleNotification,
            object: window
        )
        center.addObserver(
            self,
            selector: #selector(windowVisibilityChanged(_:)),
            name: UIWindow.didBecomeHiddenNotification,
            object: window
        )
        let notificationScope: NSObject?
        if let scope {
            notificationScope = scope
        } else {
            notificationScope = window.windowScene
        }
        if let scene = notificationScope {
            center.addObserver(
                self,
                selector: #selector(sceneActivated(_:)),
                name: UIScene.didActivateNotification,
                object: scene
            )
            center.addObserver(
                self,
                selector: #selector(sceneDeactivated(_:)),
                name: UIScene.willDeactivateNotification,
                object: scene
            )
            center.addObserver(
                self,
                selector: #selector(sceneDeactivated(_:)),
                name: UIScene.didEnterBackgroundNotification,
                object: scene
            )
            center.addObserver(
                self,
                selector: #selector(sceneDisconnected(_:)),
                name: UIScene.didDisconnectNotification,
                object: scene
            )
        } else {
            // Legacy windows have application lifecycle rather than scene lifecycle events.
            center.addObserver(
                self,
                selector: #selector(sceneActivated(_:)),
                name: UIApplication.didBecomeActiveNotification,
                object: nil
            )
            center.addObserver(
                self,
                selector: #selector(sceneDeactivated(_:)),
                name: UIApplication.willResignActiveNotification,
                object: nil
            )
            center.addObserver(
                self,
                selector: #selector(sceneDeactivated(_:)),
                name: UIApplication.didEnterBackgroundNotification,
                object: nil
            )
        }
    }

    var isAvailable: Bool {
        guard
            isValid, controller != nil, let window, let root = installedRoot,
            window.rootViewController === root
        else {
            return false
        }

        return !window.isHidden
    }

    var matchesInstalledRoot: Bool {
        guard isValid, controller != nil, let window, let root = installedRoot else {
            return false
        }

        return window.rootViewController === root
    }

    @objc private func windowVisibilityChanged(_ notification: Notification) {
        refresh()
    }

    @objc private func sceneActivated(_ notification: Notification) {
        guard isValid else {
            return
        }

        sdk?.setScreenAwareSceneActive(true)
        sdk?.setPrioritySceneActive(true)
        onChange?()
    }

    @objc private func sceneDeactivated(_ notification: Notification) {
        guard isValid else {
            return
        }

        sdk?.setScreenAwareSceneActive(false)
        sdk?.setPrioritySceneActive(false)
        onChange?()
    }

    @objc private func sceneDisconnected(_ notification: Notification) {
        guard isValid else {
            return
        }

        sdk?.setScreenAwareSceneActive(false)
        sdk?.setPrioritySceneActive(false)
        invalidate()
    }

    func refresh() {
        guard isValid else {
            return
        }
        guard
            controller != nil, let window, let root = installedRoot,
            window.rootViewController === root
        else {
            invalidate()
            return
        }

        onChange?()
    }

    func invalidate() {
        guard isValid else {
            return
        }

        isValid = false
        let visible = sdk?.active
        let parked = sdk?.parkedFollowing
        let candidate = sdk?.screenCandidateController
        sdk?.screenPriorityVisit = nil
        sdk?.screenPriorityAliasesFollowing = false
        sdk?.screenCandidateVisit = nil
        sdk?.parkedFollowing = nil
        sdk?.screenCandidateController = nil
        sdk?.active = nil
        visible?.interrupt()
        parked?.interrupt()
        candidate?.interrupt()
        sdk?.screenCandidatePending?.cancel()
        sdk?.screenCandidateLifetime?.cancel()
        sdk?.screenCandidatePending = nil
        sdk?.screenCandidateLifetime = nil
        sdk?.screenCandidateVisit = nil
        sdk?.pendingPresentation?.cancel()
        center.removeObserver(self)
        if let sdk, sdk.followingHost === self {
            sdk.followingHost = nil
            sdk.followingHostExpected = false
        }
        if
            let window, let sentinel,
            objc_getAssociatedObject(window, &followingWindowSentinelKey) as AnyObject? ===
            sentinel
        {
            objc_setAssociatedObject(
                window,
                &followingWindowSentinelKey,
                nil,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
        sentinel = nil
        onChange?()
        onChange = nil
    }

    deinit { center.removeObserver(self) }
}

@MainActor
private final class FollowingWindowSentinel {
    weak var host: FollowingHost?
    init(host: FollowingHost) {
        self.host = host
    }

    deinit {
        let host = host
        Task { @MainActor [weak host] in host?.invalidate() }
    }
}

private var followingWindowSentinelKey: UInt8 = 0

extension Skyra {
    @discardableResult
    func registerFollowingHost(
        _ controller: UIViewController,
        in window: UIWindow
    ) -> FollowingHost {
        if
            let current = followingHost, current.controller === controller,
            current.window === window, current.matchesInstalledRoot
        {
            followingHostExpected = true
            followingLifetime?.refresh()
            return current
        }
        followingHost?.invalidate()
        let host = FollowingHost(sdk: self, controller: controller, window: window)
        followingHost = host
        followingHostExpected = true
        followingLifetime?.refresh()
        return host
    }

    func unregisterFollowingHost(_ controller: UIViewController) {
        guard followingHost?.controller === controller else {
            return
        }

        followingHost?.invalidate()
        followingHost = nil
        followingHostExpected = false
        followingLifetime?.refresh()
    }
}

@MainActor
final class FollowingOverlayController: UIViewController {
    weak var sdk: Skyra?
    private var followingHost: FollowingHost?

    init(sdk: Skyra) {
        self.sdk = sdk
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("Use FollowingOverlayController.init(sdk:)")
    }

    override func loadView() {
        view = FollowingOverlayView { [weak self] in self?.registerIfAttachedOrRefresh() }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        registerIfAttached()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        registerIfAttached()
        followingHost?.refresh()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        followingHost?.refresh()
    }

    private func registerIfAttached() {
        guard let sdk, let window = viewIfLoaded?.window else {
            return
        }

        followingHost = sdk.registerFollowingHost(self, in: window)
    }

    private func registerIfAttachedOrRefresh() {
        if viewIfLoaded?.window != nil {
            registerIfAttached()
        } else {
            followingHost?.refresh()
        }
    }
}

@MainActor
class HostObservingView: UIView {
    var onWindowChange: () -> Void
    init(onWindowChange: @escaping () -> Void) {
        self.onWindowChange = onWindowChange
        super.init(frame: .zero)
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("Use HostObservingView(onWindowChange:)")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        let callback = onWindowChange
        Task { @MainActor in callback() }
    }
}

@MainActor
private final class FollowingRootView: HostObservingView {}

@MainActor
final class FollowingOverlayView: HostObservingView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}
#endif
