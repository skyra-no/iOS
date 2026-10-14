// Shares scene activity between explicit screen and following requests.
import Foundation

extension Skyra {
    /// Reports scene activity so inactive scenes cannot launch surveys.
    public func setSceneActive(_ active: Bool) {
        sceneActive = active
        #if canImport(UIKit)
        followingLifetime?.setActive(active)
        if !active, followingLifetime == nil {
            pendingPresentation?.cancel()
        }
        #endif
    }
}
