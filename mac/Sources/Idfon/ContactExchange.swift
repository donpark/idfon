import AppKit
import Contacts
import CoreImage

/// vCard contact exchange (docs/contact-exchange.md), macOS side. The daemon
/// owns the codec (`contact.export`/`contact.import`); this file is the UI
/// seam: share a card (.vcf through the share picker), confirm an
/// `idfon://add/` deep link, open a .vcf document, save a card to the system
/// Contacts app, and show the QR form of the link. QR scanning is phone-side:
/// the Mac shows the code for the phone's camera.
enum ContactExchange {
    /// Ticket JSON from an `idfon://add/<base64url>` deep-link payload.
    static func ticketJSON(fromLink payload: String) -> String? {
        var base64 = payload.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// A ticket's display name: the `label` the sharer chose, else the account id.
    static func name(ofTicketJSON ticketJSON: String) -> String? {
        guard let ticket = try? JSONSerialization.jsonObject(with: Data(ticketJSON.utf8)) as? [String: Any] else {
            return nil
        }
        return (ticket["label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (ticket["account_id"] as? String)
    }

    /// Confirm-and-add for a received ticket (`idfon://add/` taps, .vcf
    /// documents). Mirrors the Add Channel flow's default grants.
    @MainActor
    static func confirmAdd(ticketJSON: String, app: AppModel) {
        let name = name(ofTicketJSON: ticketJSON) ?? "Contact"
        let alert = NSAlert()
        alert.messageText = "Add \(name)?"
        alert.informativeText = "Add this contact to Idfon."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            if let error = await app.addChannel(name: name, ticketJSON: ticketJSON) {
                await MainActor.run { plainSheet(title: "Contact Failed", message: error) }
            }
        }
    }

    /// Imports a received .vcf (document open) via `contact.import`, with the
    /// Add Channel default grants.
    @MainActor
    static func importVCard(text: String, app: AppModel) {
        Task {
            do {
                let names = try await app.client.importVCard(text: text)
                await app.refresh()
                await MainActor.run {
                    plainSheet(
                        title: "Import Contact",
                        message: names.isEmpty
                            ? "No idfon contact cards in this file."
                            : "Added \(names.joined(separator: ", ")).")
                }
            } catch {
                await MainActor.run { plainSheet(title: "Import Failed", message: error.localizedDescription) }
            }
        }
    }

    /// Exports a card `(vcard, link)`; `ref` nil exports this identity's own.
    static func export(
        ref: String?, client: DaemonClient = DaemonClient()
    ) async throws -> (vcard: String, link: String) {
        try await client.contactExport(ref: ref)
    }

    /// Share picker with the card as a temp .vcf. AirDrop lands it in the
    /// receiver's Contacts app; the card's `idfon://add/` URL does the rest.
    static func shareCard(ref: String?, relativeTo view: NSView) {
        Task {
            do {
                let card = try await export(ref: ref)
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("idfon-contact.vcf")
                try card.vcard.write(to: url, atomically: true, encoding: .utf8)
                await MainActor.run {
                    NSSharingServicePicker(items: [url])
                        .show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
                }
            } catch {
                await MainActor.run { plainSheet(title: "Export Failed", message: error.localizedDescription) }
            }
        }
    }

    /// Saves the card behind an `idfon://add/` link into the system Contacts
    /// app (name + URL), the handoff point for Apple's own contact sharing.
    static func saveToSystemContacts(link: String) {
        let payload = String(link.dropFirst("idfon://add/".count))
        let name = ticketJSON(fromLink: payload).flatMap(name(ofTicketJSON:))
            ?? "Idfon Contact"
        let contact = CNMutableContact()
        contact.givenName = name
        contact.urlAddresses = [CNLabeledValue(label: "idfon", value: link as NSString)]
        let request = CNSaveRequest()
        request.add(contact, toContainerWithIdentifier: nil)
        do {
            try CNContactStore().execute(request)
            plainSheet(title: "Saved", message: "The card is in your Contacts app.")
        } catch {
            plainSheet(title: "Save Failed", message: error.localizedDescription)
        }
    }

    /// QR image for a link (what the phone scans).
    static func qrImage(link: String) -> NSImage? {
        guard let data = link.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else {
            return nil
        }
        let image = NSImage(size: NSSize(width: 240, height: 240))
        image.addRepresentation(NSCIImageRep(ciImage: output))
        return image
    }

    /// "My Card": shows the `idfon://add/` QR for this identity's card, with
    /// Save (system Contacts) and Share (share picker .vcf) — the NameDrop
    /// substitute (third-party apps cannot join NameDrop itself).
    @MainActor
    static func showMyCard(relativeTo view: NSView) {
        Task {
            do {
                let card = try await export(ref: nil)
                await MainActor.run {
                    let alert = NSAlert()
                    alert.messageText = "My Card"
                    alert.informativeText = "Scan with a phone to add you, or share the card."
                    let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: 240, height: 240))
                    imageView.image = qrImage(link: card.link)
                    imageView.imageScaling = .scaleProportionallyUpOrDown
                    alert.accessoryView = imageView
                    alert.addButton(withTitle: "Save to Contacts")
                    alert.addButton(withTitle: "Share…")
                    alert.addButton(withTitle: "Close")
                    NSApp.activate(ignoringOtherApps: true)
                    switch alert.runModal() {
                    case .alertFirstButtonReturn:
                        saveToSystemContacts(link: card.link)
                    case .alertSecondButtonReturn:
                        shareCard(ref: nil, relativeTo: view)
                    default:
                        break
                    }
                }
            } catch {
                await MainActor.run { plainSheet(title: "Export Failed", message: error.localizedDescription) }
            }
        }
    }

    /// A one-message modal sheet (the app's plain error/result surface).
    private static func plainSheet(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
