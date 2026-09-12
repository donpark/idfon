import UIKit

/// Navigation controller for one tab. It reports the bottom edge of its
/// navigation chrome (`topClearance`) and accepts the Live Activity Bar's
/// content inset, applied to every controller it hosts.
///
/// The wiring lives in `LiveActivityController`, which fans both numbers out
/// to every tab and reads `topClearance` from the selected one
/// (docs/live-activity-bar-layout.md §8).
final class AppNavigationController: UINavigationController, UINavigationControllerDelegate {
    /// Fired after any layout that can move the navigation bar (push/pop,
    /// rotation, large-title collapse) so the Bar can re-anchor.
    var onLayout: (() -> Void)?
    /// Fired after a push/pop so the Bar can re-evaluate its density.
    var onVisibleControllerChanged: (() -> Void)?

    /// Bottom edge of the navigation chrome, in window points. A root tab's
    /// navigation view shares the window origin, so its frame is already in
    /// window points.
    var topClearance: CGFloat { navigationBar.frame.maxY }

    private var contentInset: CGFloat = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        onLayout?()
    }

    /// Top inset the Bar occupies; applied to every hosted controller so
    /// scroll views and Auto Layout content follow the safe area for free.
    func applyContentInset(_ top: CGFloat) {
        contentInset = top
        viewControllers.forEach { $0.additionalSafeAreaInsets.top = top }
    }

    func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController, animated: Bool) {
        // A newly pushed controller hasn't seen any contentInset change yet.
        viewController.additionalSafeAreaInsets.top = contentInset
        onVisibleControllerChanged?()
    }
}
