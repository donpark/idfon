import UIKit

/// Root navigation controller that owns the Live Activity Bar's clearance and
/// content-shift contract (docs/live-activity-bar-layout.md §8). The two
/// numbers live in one place: the navigation bar's bottom edge is reported to
/// `overlay.topClearance` (so the Bar docks below chrome, never over it), and
/// the overlay's `contentInset` is added to each child's
/// `additionalSafeAreaInsets.top` (so content shifts down under the Bar).
final class AppNavigationController: UINavigationController, UINavigationControllerDelegate {
    /// The Bar's window host, wired by the scene delegate once both exist.
    /// Weak: the scene's `LiveActivityController` owns the overlay window.
    weak var overlay: OverlayWindow? {
        didSet {
            overlay?.onContentInsetChange = { [weak self] inset in
                self?.applyContentInset(inset)
            }
            applyClearance()
            applyContentInset(overlay?.contentInset ?? 0)
        }
    }

    /// Fired after each push/pop so the Bar can re-evaluate its density
    /// (expanded only while the visible thread is the call peer's).
    var onVisibleControllerChanged: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
        applyClearance()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Fires on push/pop, rotation and large-title collapse: the nav bar
        // is this controller's own subview, so its height changes land here.
        applyClearance()
    }

    private func applyClearance() {
        guard let overlay else { return }
        // Root nav controller: `navigationBar.frame` is in window points.
        overlay.topClearance = navigationBar.frame.maxY
    }

    private func applyContentInset(_ top: CGFloat) {
        viewControllers.forEach { $0.additionalSafeAreaInsets.top = top }
    }

    func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
        // A newly pushed controller hasn't seen any contentInset change yet.
        viewController.additionalSafeAreaInsets.top = overlay?.contentInset ?? 0
        onVisibleControllerChanged?()
    }
}
