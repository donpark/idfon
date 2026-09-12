import UIKit

/// Empty-state screen for a tab whose backing data isn't built yet
/// (Favorites, Recents). Replace with the real list when the data lands —
/// see the tab discussion in docs/ui-design-notes.md.
final class PlaceholderViewController: UIViewController {
    private let symbol: String
    private let message: String

    init(title: String, symbol: String, message: String) {
        self.symbol = symbol
        self.message = message
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError("storyboards are not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.backButtonDisplayMode = .generic // show "Back", not a callee name
        var config = UIContentUnavailableConfiguration.empty()
        config.image = UIImage(systemName: symbol)
        config.text = title
        config.secondaryText = message
        contentUnavailableConfiguration = config
    }
}
