import Foundation

/// Active data transactions shown in the Bar's Session Tray
/// (docs/ui-design-notes.md §4). The single place that feeds
/// `LiveActivityBarModel.rows`; the §5 file send registers here, and media
/// streams plug in later.
///
/// Each producer registers `begin(id:peerId:name:cancel:)` with a way to stop
/// itself, then calls `update`/`finish`. `cancel(id:)` asks the producer to
/// stop; the producer calls `finish(id:)` when it actually does, so the row
/// can't disappear before the work has stopped.
@MainActor
final class TransferCenter {
    static let shared = TransferCenter()

    struct Transfer: Identifiable, Equatable {
        let id: String
        let peerId: String
        let name: String
        var fraction: Double
        var bytesPerSecond: Double
    }

    /// Fired after any change (begin/update/finish). The host re-renders.
    var onChange: (() -> Void)?

    private struct Entry {
        var transfer: Transfer
        let cancel: () -> Void
    }
    private var items: [Entry] = []

    /// Active transactions, in the order they began.
    var transfers: [Transfer] { items.map(\.transfer) }

    /// Peer ids with an in-flight transaction, for compact pills on screens
    /// that don't show the owning thread (§6).
    var activePeerIds: [String] { Array(Set(items.map(\.transfer.peerId))).sorted() }

    func begin(id: String, peerId: String, name: String, cancel: @escaping () -> Void) {
        items.append(Entry(
            transfer: Transfer(id: id, peerId: peerId, name: name, fraction: 0, bytesPerSecond: 0),
            cancel: cancel))
        NSLog("idfon tray: begin peer=\(peerId) name=\(name) id=\(id)")
        onChange?()
    }

    func update(id: String, fraction: Double, bytesPerSecond: Double) {
        guard let index = items.firstIndex(where: { $0.transfer.id == id }) else { return }
        items[index].transfer.fraction = min(max(fraction, 0), 1)
        items[index].transfer.bytesPerSecond = bytesPerSecond
        onChange?()
    }

    func finish(id: String) {
        guard let index = items.firstIndex(where: { $0.transfer.id == id }) else { return }
        let name = items[index].transfer.name
        items.remove(at: index)
        NSLog("idfon tray: finish name=\(name) id=\(id)")
        onChange?()
    }

    /// Asks the producer to stop. The row stays until it calls `finish(id:)`.
    func cancel(id: String) {
        guard let entry = items.first(where: { $0.transfer.id == id }) else { return }
        NSLog("idfon tray: cancel name=\(entry.transfer.name) id=\(id)")
        entry.cancel()
    }

    /// Tray rows for one peer. Row ids are the transfer ids, so a Cancel intent
    /// routes straight back through `cancel(id:)`.
    func rows(for peerId: String) -> [LiveActivityBarModel.Row] {
        transfers.filter { $0.peerId == peerId }.map {
            .init(id: $0.id, name: $0.name,
                  kind: .transfer(fraction: $0.fraction, bytesPerSecond: $0.bytesPerSecond))
        }
    }
}
