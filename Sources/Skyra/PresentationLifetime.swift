// Observes the requesting UIKit screen while the popup is attached above the app.
#if canImport(UIKit)
import UIKit

/// A child controller receives screen disappearance without replacing the app's navigation delegate.
@MainActor
final class PresentationLifetime: UIViewController {
    var onDisappear: (() -> Void)?

    /// Install before delivery lookup so navigating away also invalidates pending requests.
    func attach(to owner: UIViewController) {
        owner.addChild(self)
        view.isUserInteractionEnabled = false
        view.frame = .zero
        owner.view.addSubview(view)
        didMove(toParent: owner)
    }

    /// The request removes its observer after returning, without generating another interruption.
    func detach() {
        onDisappear = nil
        willMove(toParent: nil)
        view.removeFromSuperview()
        removeFromParent()
    }

    /// Completed transitions end this screen's request; cancelled interactive transitions do not.
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onDisappear?()
    }
}
#endif
