import UIKit

/// §5.4: the list screens' empty / loading / error states share one
/// vocabulary, shaped as actions not prose (P11). Rendered only while the
/// list itself is empty — a loaded list always wins over a state view.
enum ListState {
    case loading
    case empty(symbol: String, title: String)
    /// Load failed; the payload retries.
    case failed(() -> Void)

    @MainActor
    func apply(to tableView: UITableView, rows: Int) {
        guard rows == 0 else {
            tableView.backgroundView = nil
            return
        }
        switch self {
        case .loading:
            tableView.backgroundView = UIContentUnavailableConfiguration.loading().makeContentView()
        case .empty(let symbol, let title):
            var config = UIContentUnavailableConfiguration.empty()
            config.image = UIImage(systemName: symbol)
            config.text = title
            tableView.backgroundView = config.makeContentView()
        case .failed(let retry):
            var config = UIContentUnavailableConfiguration.empty()
            config.image = UIImage(systemName: "exclamationmark.triangle")
            config.text = "Couldn't load"
            config.buttonProperties.primaryAction = UIAction(title: "Retry") { _ in retry() }
            tableView.backgroundView = config.makeContentView()
        }
    }
}
