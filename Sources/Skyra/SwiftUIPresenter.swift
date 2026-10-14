// Connects a screen or a root SwiftUI overlay to its scene-local UIKit host.
#if canImport(UIKit)
import SwiftUI
import UIKit

/// A SwiftUI adapter that supplies Skyra with a scene-local UIKit host.
/// This value describes the adapter; SwiftUI retains the actual AnchorController across redraws.
public struct SkyraPresenter: UIViewControllerRepresentable {
    private let skyra: Skyra

    /// The app or root modifier supplies the SDK instance whose surveys this view will host.
    public init(_ skyra: Skyra) {
        self.skyra = skyra
    }

    /// SwiftUI calls this once when installing the adapter; the anchor reports its host after attachment.
    public func makeUIViewController(context: Context) -> UIViewController {
        let controller = AnchorController()
        controller.skyra = skyra
        return controller
    }

    /// SwiftUI calls this on updates. Transfer host ownership if the view now uses a different SDK.
    public func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        guard
            let anchor = uiViewController as? AnchorController,
            anchor.skyra !== skyra
        else {
            return
        }

        if anchor.skyra?.presenter == nil || anchor.skyra?.presenter === anchor {
            anchor.skyra?.setPresenter(nil)
        }
        anchor.skyra = skyra
        if anchor.viewIfLoaded?.window != nil {
            skyra.setPresenter(anchor)
        }
    }

    /// SwiftUI calls this when removing the adapter. Release only this anchor's host registration.
    public static func dismantleUIViewController(
        _ uiViewController: UIViewController,
        coordinator: ()
    ) {
        guard let anchor = uiViewController as? AnchorController else {
            return
        }

        if anchor.skyra?.presenter == nil || anchor.skyra?.presenter === anchor {
            anchor.skyra?.setPresenter(nil)
        }
    }
}

/// Root-only overlay host for installation-owned surveys. Unlike SkyraPresenter this never replaces
/// the SDK's screen-mode presenter and its transparent surface yields empty-space touches.
struct FollowingPresenter: UIViewControllerRepresentable {
    let sdk: Skyra

    init(_ sdk: Skyra) {
        self.sdk = sdk
    }

    func makeUIViewController(context: Context) -> UIViewController {
        FollowingOverlayController(sdk: sdk)
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        (controller as? FollowingOverlayController)?.sdk = sdk
    }

    static func dismantleUIViewController(_ controller: UIViewController, coordinator: ()) {
        guard let overlay = controller as? FollowingOverlayController else {
            return
        }

        overlay.sdk?.unregisterFollowingHost(overlay)
        overlay.sdk = nil
    }
}

/// A real UIKit controller gives the SwiftUI adapter a host in the correct window scene.
@MainActor
private final class AnchorController: UIViewController {
    weak var skyra: Skyra?

    /// UIKit calls this once attached; only then can Skyra safely present a child popup here.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        skyra?.setPresenter(self)
    }
}
#endif
