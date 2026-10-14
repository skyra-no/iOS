// Owns one floating survey popup: WebView callbacks, native UI, and final teardown.
// Presentation.swift creates this controller; Bridge.swift interprets its incoming page messages.
#if canImport(UIKit)
import UIKit
import WebKit

/// The UIKit owner of one survey presentation, from WebView creation through removal.
/// It is a UIViewController so UIKit manages attachment, layout, and accessibility callbacks.
@MainActor
final class SurveyController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate,
    UIGestureRecognizerDelegate
{
    enum OwnershipRole: Equatable {
        case manual
        case installationFollowing
        case screenVisit
    }

    let bridge: Bridge
    let configuration: SkyraConfiguration
    let store: StateStore
    let initialization: String
    /// Resumes Skyra.presentSurvey after the popup has been removed, including any exit animation.
    var onFinish: ((Result<SkyraResult, Error>) -> Void)?
    private var finalResult: Result<SkyraResult, Error>?
    private var finishObservers: [UUID: (Result<SkyraResult, Error>) -> Void] = [:]
    /// Called synchronously at the first visual reveal so screen priority can transfer atomically.
    var onWillReveal: (() -> Bool)?
    /// Navigation-owned controllers survive temporary host disappearance; the coordinator decides when to resume or interrupt.
    var followsNavigation = false
    var ownershipRole: OwnershipRole = .manual
    private var suspended = false

    func observeFinish(_ observer: @escaping (Result<SkyraResult, Error>) -> Void) -> UUID {
        let id = UUID()
        if let finalResult {
            observer(finalResult)
        } else {
            finishObservers[id] = observer
        }
        return id
    }

    func removeFinishObserver(_ id: UUID) {
        finishObservers.removeValue(forKey: id)
    }

    private(set) var webView: WKWebView!
    private let spinner = UIActivityIndicatorView(style: .large)
    private var timeout: Task<Void, Never>?
    private var initializing = false
    private var rejecting = false
    private var rejectionTask: Task<Void, Never>?
    private var hasNavigated = false
    private let shadow = PopupOverlayView()
    private let popup = UIView()
    private let close = UIButton(type: .system)
    private let dragHandle = UIView()
    private var popupTop: NSLayoutConstraint!
    private(set) var placement = PopupPlacement()
    private var dragStart: CGPoint?
    private lazy var pillPan = UIPanGestureRecognizer(
        target: self,
        action: #selector(dragPopup(_:))
    )
    private var webTop: NSLayoutConstraint!
    private(set) var popupLayout: PopupLayout?
    private var renderedLayout: PopupLayout?
    private var pendingLayout: PopupLayout?
    private var layoutScheduled = false
    private var observers: [NSObjectProtocol] = []
    private var sentTextScale: Double?
    private weak var previousFocus: NSObject?
    private var focusedPopup = false
    private(set) var revealed = false
    private var preparedForReveal = false
    private(set) var visualReadinessSupported: Bool?
    private var legacyFallback: Task<Void, Never>?
    private var legacyFallbackElapsed = false

    // MARK: Setup and loading

    /// Presentation and live updates use this to convert native Dynamic Type into the page's supported scale.
    static func textScale(for traits: UITraitCollection) -> Double {
        min(3, max(1, Double(UIFontMetrics(forTextStyle: .body)
                .scaledValue(for: 17, compatibleWith: traits) / 17)))
    }

    private let loadHostedPage: @MainActor (WKWebView, URLRequest) -> Void

    /// Presentation creates one controller after policy and storage preparation succeed. Bind its bridge
    /// to the same survey/visitor/session; UIKit constructs the actual views later through loadView.
    init(
        slug: String,
        configuration: SkyraConfiguration,
        store: StateStore,
        visitor: String,
        session: String,
        initialization: String,
        loadHostedPage: @escaping @MainActor (WKWebView, URLRequest) -> Void = { webView, request in
            webView.load(request)
        }
    ) {
        self.configuration = configuration
        self.store = store
        self.initialization = initialization
        self.loadHostedPage = loadHostedPage
        bridge = Bridge(
            slug: slug,
            visitor: visitor,
            session: session,
            origin: Origin(configuration.hostedOrigin)!
        )
        super.init(nibName: nil, bundle: nil)
    }

    /// Required by UIViewController, but storyboard loading cannot supply the SDK's prepared identity/state.
    required init?(coder: NSCoder) {
        fatalError("Use Skyra.presentSurvey")
    }

    /// UIKit calls this to create a transparent overlay that passes surrounding touches back to the app.
    override func loadView() {
        view = PopupOverlayView()
        view.isHidden = suspended
        view.isUserInteractionEnabled = !suspended
        view.accessibilityElementsHidden = suspended
    }

    /// UIKit calls this on first loading: build the hidden popup, register WebKit messages and native
    /// observers, then load the hosted URL. Visibility waits for the page's readiness and valid layout.
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        if !followsNavigation {
            previousFocus =
                UIAccessibility.focusedElement(using: .notificationVoiceOver) as? NSObject
        }
        shadow.layer.shadowColor = UIColor.black.cgColor
        shadow.layer.shadowOpacity = 0.18
        shadow.layer.shadowRadius = 16
        shadow.layer.shadowOffset = CGSize(width: 0, height: 6)
        shadow.alpha = 0
        shadow.isUserInteractionEnabled = false
        shadow.accessibilityElementsHidden = true
        popup.backgroundColor = .systemBackground
        popup.layer.cornerRadius = 20
        popup.layer.cornerCurve = .continuous
        popup.clipsToBounds = true
        popup.accessibilityIdentifier = "skyra.popup"
        popup.translatesAutoresizingMaskIntoConstraints = false

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(self, name: "skyra")
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.translatesAutoresizingMaskIntoConstraints = false
        close.setImage(UIImage(systemName: "xmark"), for: .normal)
        close.tintColor = .secondaryLabel
        close.accessibilityLabel = "Close survey"
        close.accessibilityIdentifier = "skyra.close"
        close.addTarget(self, action: #selector(closePressed), for: .touchUpInside)
        close.translatesAutoresizingMaskIntoConstraints = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(shadow)
        shadow.addSubview(popup)
        popup.addSubview(webView)
        popup.addSubview(close)
        popup.addSubview(spinner)
        dragHandle.accessibilityIdentifier = "skyra.dragHandle"
        dragHandle.backgroundColor = .secondarySystemBackground
        dragHandle.layer.cornerRadius = 10
        let grip = UIView()
        grip.backgroundColor = .secondaryLabel
        grip.layer.cornerRadius = 2
        grip.frame = CGRect(x: 20, y: 10, width: 24, height: 4)
        grip.isUserInteractionEnabled = false
        dragHandle.addSubview(grip)
        shadow.addSubview(dragHandle)
        dragHandle.addGestureRecognizer(UIPanGestureRecognizer(
            target: self,
            action: #selector(dragPopup(_:))
        ))
        pillPan.delegate = self
        pillPan.cancelsTouchesInView = true
        popup.addGestureRecognizer(pillPan)
        webView.scrollView.panGestureRecognizer.require(toFail: pillPan)
        popupTop = popup.topAnchor.constraint(equalTo: shadow.topAnchor, constant: 24)
        webTop = webView.topAnchor.constraint(equalTo: popup.topAnchor, constant: 48)
        webTop.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            popup.leadingAnchor.constraint(equalTo: shadow.leadingAnchor),
            popup.trailingAnchor.constraint(equalTo: shadow.trailingAnchor),
            popupTop,
            popup.bottomAnchor.constraint(equalTo: shadow.bottomAnchor),
            close.topAnchor.constraint(equalTo: popup.topAnchor, constant: 4),
            close.trailingAnchor.constraint(equalTo: popup.trailingAnchor, constant: -4),
            close.widthAnchor.constraint(equalToConstant: 44),
            close.heightAnchor.constraint(equalToConstant: 44),
            webTop,
            webView.heightAnchor.constraint(greaterThanOrEqualToConstant: 0),
            webView.leadingAnchor.constraint(equalTo: popup.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: popup.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: popup.bottomAnchor),
            spinner.centerXAnchor.constraint(equalTo: webView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: webView.centerYAnchor),
        ])
        spinner.startAnimating()
        for name in [
            UIContentSizeCategory.didChangeNotification,
            UIApplication.didBecomeActiveNotification,
        ] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.updateTextScale() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }

                // Frame-based placement must be invalidated when the keyboard guide moves,
                // even when no hosted size report or host resize accompanies that change.
                self.view.setNeedsLayout()
            }
        })
        var url = URLComponents(url: configuration.hostedOrigin, resolvingAgainstBaseURL: false)!
        url.path = "/app.html"
        url.queryItems = [URLQueryItem(name: "slug", value: bridge.slug)]
        loadHostedPage(webView, URLRequest(url: url.url!))
        timeout = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 30_000_000_000)
            } catch {
                return
            }
            self?.preparationTimedOut()
        }
    }

    // MARK: Showing and laying out the popup

    /// UIKit reports host attachment here, satisfying one of the prerequisites for revealing the popup.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        revealIfReady()
    }

    /// The initialization JavaScript callback reports whether this page supports explicit visual readiness.
    /// Save the capability once so revealIfReady can choose the modern or legacy readiness path.
    func detectVisualReadiness(_ supported: Bool) {
        guard !bridge.finished, !rejecting, visualReadinessSupported == nil else {
            return
        }

        visualReadinessSupported = supported
        revealIfReady()
    }

    /// The startup deadline calls this when an unrevealed popup has taken too long to become usable.
    func preparationTimedOut() {
        guard !revealed, !rejecting, !(followsNavigation && preparedForReveal) else {
            return
        }

        finish(.success(.failure(bridge.ready ? "visual_readiness_timeout" : "startup_timeout")))
    }

    /// Page events, layout application, and host attachment all retry this until their prerequisites agree.
    /// Reveal once, cancel startup timers, and move accessibility focus into the visible survey.
    func revealIfReady() {
        guard
            !revealed,
            !bridge.finished,
            !rejecting,
            bridge.ready,
            let supported = visualReadinessSupported
        else {
            return
        }

        // Screen-scoped presentations retain their original visibility-gated preparation behavior.
        if !followsNavigation, suspended {
            return
        }

        if supported {
            guard bridge.visualReady, popupLayout?.webControls == true else {
                return
            }
        } else if popupLayout == nil && !legacyFallbackElapsed {
            if legacyFallback == nil {
                legacyFallback = Task { [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                    } catch {
                        return
                    }
                    self?.legacyFallbackElapsed = true
                    self?.revealIfReady()
                }
            }
            return
        }

        if followsNavigation {
            preparedForReveal = true
            timeout?.cancel()
            timeout = nil
        }
        guard viewIfLoaded?.window != nil, parent != nil else {
            return
        }

        if onWillReveal?() == false {
            return
        }
        guard !suspended else {
            return
        }

        view.layoutIfNeeded()
        revealed = true
        timeout?.cancel()
        timeout = nil
        legacyFallback?.cancel()
        legacyFallback = nil
        spinner.stopAnimating()
        shadow.isUserInteractionEnabled = true
        shadow.accessibilityElementsHidden = false
        shadow.transform = UIAccessibility.isReduceMotionEnabled ? .identity : CGAffineTransform(
            translationX: 0,
            y: 12
        )
        UIView.animate(
            withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.25,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
            self.shadow.alpha = 1
            self.shadow.transform = .identity
        }
        if !followsNavigation {
            previousFocus =
                UIAccessibility.focusedElement(using: .notificationVoiceOver) as? NSObject
            focusedPopup = true
            UIAccessibility.post(notification: .layoutChanged, argument: webView)
        }
    }

    /// Temporarily hides the popup without changing its page or identity; hosted work may continue underneath.
    func setSuspended(_ suspended: Bool) {
        guard self.suspended != suspended else {
            return
        }

        self.suspended = suspended
        if suspended {
            viewIfLoaded?.endEditing(true)
            viewIfLoaded?.isUserInteractionEnabled = false
            viewIfLoaded?.accessibilityElementsHidden = true
            viewIfLoaded?.isHidden = true
            return
        }

        viewIfLoaded?.isHidden = false
        viewIfLoaded?.isUserInteractionEnabled = true
        viewIfLoaded?.accessibilityElementsHidden = false
        viewIfLoaded?.setNeedsLayout()
        viewIfLoaded?.layoutIfNeeded()
        revealIfReady()
    }

    /// UIKit calls this after size, keyboard, or safe-area changes; recompute placement and visible radius.
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutPopup()
        let radius = CGFloat(popupLayout?.cornerRadius ?? 20)
        popup.layer.cornerRadius = min(
            radius,
            max(0, min(popup.bounds.width, popup.bounds.height) / 2)
        )
    }

    /// Layout callbacks and dragging use this to combine safe bounds, keyboard/tab-bar avoidance,
    /// hosted measurements, and the remembered corner into the current native popup frame.
    private func layoutPopup() {
        let safe = view.safeAreaLayoutGuide.layoutFrame
        var bottom = min(safe.maxY, view.keyboardLayoutGuide.layoutFrame.minY)
        /// This layout pass walks the attached host only, shrinking usable space above visible tab bars.
        func avoidTabBars(_ node: UIView) {
            guard node !== view, !node.isHidden, node.alpha > 0.01 else {
                return
            }

            if let bar = node as? UITabBar {
                let rect = bar.convert(bar.bounds, to: view)
                if rect.intersects(safe) {
                    bottom = min(bottom, rect.minY)
                }
            }
            node.subviews.forEach(avoidTabBars)
        }
        if let host = parent?.view {
            avoidTabBars(host)
        }
        let available = CGRect(
            x: safe.minX + min(16, safe.width / 2),
            y: safe.minY + 16,
            width: max(0, safe.width - 32),
            height: max(0, bottom - safe.minY - 32)
        )
        let handle: CGFloat = popupLayout?.minimized == true ? 0 : 24
        shadow.frame = placement.frame(in: available, layout: renderedLayout, handleHeight: handle)
        popupTop.constant = min(handle, shadow.bounds.height)
        dragHandle.isHidden = handle == 0
        dragHandle.frame = CGRect(
            x: max(0, (shadow.bounds.width - 64) / 2),
            y: 0,
            width: min(64, shadow.bounds.width),
            height: min(handle, shadow.bounds.height)
        )
        shadow.layoutIfNeeded()
    }

    /// UIKit asks before dragging. The pill can drag only while minimized; closing/hidden popups cannot.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        revealed && !rejecting && !bridge.finished &&
            (gestureRecognizer !== pillPan || popupLayout?.minimized == true)
    }

    /// The pan handler supplies the user's desired corner. Preserve it even when current bounds clamp it.
    func movePopup(to corner: CGPoint) {
        guard
            revealed,
            !rejecting,
            !bridge.finished,
            corner.x.isFinite,
            corner.y.isFinite
        else {
            return
        }

        placement.desiredCorner = corner
        layoutPopup()
    }

    /// UIKit's pan recognizers call this to translate an expanded handle or minimized pill into movement.
    @objc private func dragPopup(_ pan: UIPanGestureRecognizer) {
        guard revealed, !rejecting, !bridge.finished else {
            return
        }

        if pan.state == .began {
            dragStart = CGPoint(x: shadow.frame.maxX, y: shadow.frame.maxY)
        }
        if
            let start = dragStart,
            pan.state == .began || pan.state == .changed || pan.state == .ended
        {
            let delta = pan.translation(in: view)
            movePopup(to: CGPoint(x: start.x + delta.x, y: start.y + delta.y))
        }
        if
            pan.state == .ended
            || pan.state == .cancelled
            || pan.state == .failed
        {
            dragStart = nil
        }
    }

    /// A bridge layout event calls this. Coalesce reports on the main queue, update hosted/native chrome,
    /// and animate geometry without allowing temporary keyboard clamping to replace intrinsic height.
    func applyLayout(_ layout: PopupLayout) {
        guard bridge.ready, !bridge.finished, !rejecting, layout.isValid else {
            return
        }

        pendingLayout = layout
        if layoutScheduled {
            return
        }

        layoutScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            self.layoutScheduled = false
            guard
                !self.bridge.finished,
                !self.rejecting,
                let layout = self.pendingLayout
            else {
                return
            }

            self.pendingLayout = nil
            defer {
                self.revealIfReady()
            }
            let previous = self.renderedLayout
            // Keep intrinsic height independent of the keyboard-clamped rendered height.
            self.popupLayout = layout
            let tolerance = 1 / (self.view.window?.screen.scale ?? 2)
            guard
                previous?.webControls != layout.webControls
                || previous?.minimized != layout.minimized
                || previous?.contentWidth != layout.contentWidth
                || abs((previous?.preferredHeight ?? 420) - layout.preferredHeight) >=
                Double(tolerance)
                || previous?.cornerRadius != layout.cornerRadius
            else {
                return
            }

            self.view.layoutIfNeeded()
            self.renderedLayout = layout
            self.close.isHidden = layout.webControls
            self.popup.backgroundColor = layout.webControls ? .clear : .systemBackground
            self.webTop.constant = layout.webControls ? 0 : 48
            self.view.setNeedsLayout()
            UIView.animate(
                withDuration: !self.revealed || UIAccessibility.isReduceMotionEnabled ? 0 : 0.25,
                delay: 0,
                options: [.beginFromCurrentState, .allowUserInteraction]
            ) {
                self.view.layoutIfNeeded()
            }
        }
    }

    /// Readiness, Dynamic Type, and foreground notifications call this to send changed native text scale.
    /// Feature detection keeps older hosted pages working when they lack the live scale API.
    private func updateTextScale() {
        guard bridge.ready, !bridge.finished, !rejecting else {
            return
        }

        let scale = Self.textScale(for: traitCollection)
        if scale == sentTextScale {
            return
        }

        sentTextScale = scale
        webView.callAsyncJavaScript(
            "if (typeof window.skyraApp?.setTextScale === 'function') { window.skyraApp.setTextScale(scale); }",
            arguments: ["scale": scale],
            in: nil,
            in: .page,
            completionHandler: nil
        )
    }

    // MARK: Ending the presentation

    /// The native close button calls this; intentional dismissal follows the same rejection path as the app.
    @objc private func closePressed() {
        reject()
    }

    /// VoiceOver's escape gesture requests the same rejection and cleanup as pressing Close.
    override func accessibilityPerformEscape() -> Bool {
        reject()
        return true
    }

    /// Screen-scoped presentations end when their screen disappears. Following presentations are
    /// retained here; UIKit naturally covers their host during navigation and modal presentation.
    func interrupt() {
        // An explicit Close already owns its bounded rejection cleanup.
        if rejecting {
            return
        }

        finish(.success(.interrupted))
    }

    /// A view-scoped task ending interrupts presentation without treating navigation as rejection.
    func cancel() {
        interrupt()
    }

    func cancelBeforeReveal() {
        if revealed {
            interrupt()
        } else {
            finish(.failure(CancellationError()))
        }
    }

    /// Close, escape, or dismissSurvey calls this to persist rejection, ask the page to reject, and finish
    /// after its reply or a bounded timeout. Previously accepted answers always retain completion.
    func reject(cancelled: Bool = false) {
        guard !bridge.finished, !rejecting else {
            return
        }

        if bridge.accepted {
            finish(.success(.completed))
            return
        }
        rejecting = true
        notifyTerminal()
        timeout?.cancel()
        timeout = nil
        legacyFallback?.cancel()
        legacyFallback = nil
        pendingLayout = nil
        // Keep the page alive for reject(), but never depend on its reply for local cleanup.
        let result: Result<SkyraResult, Error> = cancelled ? .failure(CancellationError()) :
            .success(.rejected)
        // Record synchronously, including dismissal before navigation or readiness.
        do {
            try store.terminal(
                slug: bridge.slug,
                visitor: bridge.visitor,
                session: bridge.session,
                status: .rejected
            )
        } catch {
            finish(.failure(SkyraError.storageFailure))
            return
        }
        guard let webView else {
            finish(result, rejected: true)
            return
        }

        webView.evaluateJavaScript("window.skyraApp?.reject()") { [weak self] _, _ in
            self?.finish(result, rejected: true)
        }
        rejectionTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return
            }
            self?.finish(result, rejected: true)
        }
    }

    /// Host disappearance interrupts an unfinished popup without clearing its progress.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if !bridge.finished, !followsNavigation {
            interrupt()
        }
    }

    /// Ends this popup: saves the outcome, stops pending work, removes the view, and calls onFinish.
    /// Completion, dismissal, cancellation, and errors all arrive here; only the first call proceeds.
    func finish(_ result: Result<SkyraResult, Error>, rejected: Bool = false) {
        // A page reply and native cancellation can both request cleanup for the same popup.
        if bridge.finished {
            return
        }
        bridge.stopReceivingMessages()
        notifyTerminal()
        var result = result
        if bridge.accepted {
            // Preserve explicit storage failures; other cleanup cannot undo accepted answers.
            switch result {
            case .failure(let error) where error as? SkyraError == .storageFailure:
                break
            default:
                result = .success(.completed)
            }
        }
        let status: SkyraSavedState.Status?
        if bridge.accepted {
            status = .completed
        } else if rejected {
            status = .rejected
        } else if case .success(.completed) = result {
            status = .completed
        } else if case .success(.rejected) = result {
            status = .rejected
        } else {
            status = nil
        }
        if let status {
            do {
                try store.terminal(
                    slug: bridge.slug,
                    visitor: bridge.visitor,
                    session: bridge.session,
                    status: status
                )
            } catch {
                result = .failure(SkyraError.storageFailure)
            }
        }
        finalResult = result
        let finishCallbacks = Array(finishObservers.values)
        finishObservers.removeAll()
        finishCallbacks.forEach { $0(result) }
        timeout?.cancel()
        timeout = nil
        legacyFallback?.cancel()
        legacyFallback = nil
        pendingLayout = nil
        rejectionTask?.cancel()
        rejectionTask = nil
        self.observers.forEach(NotificationCenter.default.removeObserver)
        self.observers.removeAll()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "skyra")
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        let callback = onFinish
        onFinish = nil
        let teardown = {
            if self.parent != nil {
                self.willMove(toParent: nil)
                self.view.removeFromSuperview()
                self.removeFromParent()
            }
            if
                !self.followsNavigation, !self.suspended, self.focusedPopup,
                let focus = self.previousFocus as? UIView, focus.window != nil
            {
                UIAccessibility.post(notification: .layoutChanged, argument: focus)
            } else if
                !self.followsNavigation, !self.suspended, self.focusedPopup,
                let focus = self.previousFocus as? UIAccessibilityElement,
                let container = focus.accessibilityContainer as? UIView, container.window != nil
            {
                UIAccessibility.post(notification: .layoutChanged, argument: focus)
            }
            callback?(result)
        }
        guard !suspended, revealed, viewIfLoaded?.window != nil, parent != nil else {
            teardown()
            return
        }

        UIView.animate(
            withDuration: 0.25,
            delay: 0,
            options: [.beginFromCurrentState, .allowUserInteraction],
            animations: {
                self.shadow.alpha = 0
                self.shadow.transform = UIAccessibility.isReduceMotionEnabled ? .identity :
                    CGAffineTransform(
                        translationX: 0,
                        y: 12
                    )
            },
            completion: { _ in teardown() }
        )
    }

    /// Disable interaction as soon as a terminal result starts teardown.
    private func notifyTerminal() {
        shadow.isUserInteractionEnabled = false
        dragStart = nil
    }

    // MARK: WebKit message and navigation callbacks

    /// WebKit delivers window.webkit.messageHandlers.skyra.postMessage here. Pass JSON and its source
    /// to Bridge, then act on the returned event: reveal, resize, persist state, or finish the popup.
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard
            message.webView === webView,
            !rejecting,
            JSONSerialization.isValidJSONObject(message.body),
            let data = try? JSONSerialization.data(withJSONObject: message.body)
        else {
            return
        }

        let security = message.frameInfo.securityOrigin
        var components = URLComponents()
        components.scheme = security.protocol
        components.host = security.host
        if security.port != 0 {
            components.port = security.port
        }
        let source = components.url.flatMap(Origin.init)
        switch bridge.receive(
            data,
            mainFrame: message.frameInfo.isMainFrame,
            source: source,
            now: Clock.nowMilliseconds()
        ) {
        case .ready:
            updateTextScale()
            revealIfReady()

        case .visualReady:
            revealIfReady()
        case .layout(let layout):
            applyLayout(layout)
        case .state(let state):
            do {
                try store.save(state)
            } catch {
                finish(.failure(SkyraError.storageFailure))
            }

        case .terminal(let result):
            finish(.success(result))
        case .recoverable, .ignored:
            break
        }
    }

    /// WebKit reports document loading here. Wait for the page's initialize function, supply native state,
    /// and detect visual-readiness support. Document loading alone does not reveal the popup.
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !initializing, !bridge.finished else {
            return
        }

        initializing = true
        // The module may finish after didFinish. Pass JSON as an argument, never as executable source.
        let script = """
        const deadline = Date.now() + 8000;
        while (!window.skyraApp?.initialize) {
          if (Date.now() > deadline) throw new Error('initialization_timeout');
          await new Promise(resolve => setTimeout(resolve, 25));
        }
        const initialization = JSON.parse(payload);
        // Earlier v1 pages use a strict schema with no textScale field.
        if (typeof window.skyraApp.setTextScale !== 'function') delete initialization.textScale;
        const visualReadinessSupported = window.skyraApp.visualReadinessVersion === 1;
        window.skyraApp.initialize(initialization);
        return visualReadinessSupported;
        """
        webView.callAsyncJavaScript(
            script,
            arguments: ["payload": initialization],
            in: nil,
            in: .page,
            completionHandler: { [weak self] result in
                guard let self, !self.rejecting, !self.bridge.finished else {
                    return
                }

                switch result {
                case .failure:
                    self.finish(.success(.failure("initialization_failed")))
                case .success(let value):
                    self.detectVisualReadiness(value as? Bool == true)
                }
            }
        )
    }

    /// WebKit asks before navigating. Permit only the initial top-level app.html request at the configured
    /// origin, so subsequent links or frames cannot replace the active survey page.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard
            navigationAction.targetFrame?.isMainFrame == true,
            let url = navigationAction.request.url,
            Origin(url) == bridge.origin,
            url.path == "/app.html",
            !hasNavigated
        else {
            decisionHandler(.cancel)
            return
        }

        hasNavigated = true
        decisionHandler(.allow)
    }

    /// WebKit reports an established navigation failure here; route it through the shared failure policy.
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }

    /// WebKit reports a failure before navigation commits here; apply the same policy as a later failure.
    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        navigationFailed(error)
    }

    /// Both navigation-error callbacks use this to finish real load failures while ignoring expected
    /// cancellation during page shutdown or a rejection already being handled.
    private func navigationFailed(_ error: Error) {
        if rejecting {
            return
        }

        if (error as NSError).code != NSURLErrorCancelled {
            finish(.success(.failure("load_failed")))
        }
    }

    /// WebKit calls this if its content process dies. End the popup unless rejection already owns cleanup.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if rejecting {
            return
        }

        finish(.success(.failure("web_process_terminated")))
    }
}

/// Only the popup receives touches; the surrounding app stays interactive.
private final class PopupOverlayView: UIView {
    /// UIKit's hit testing calls this. Empty overlay space returns nil so the surrounding app stays usable.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

#endif
