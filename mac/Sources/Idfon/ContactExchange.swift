import AppKit
import Contacts
import CoreImage

/// vCard contact exchange (docs/contact-exchange.md), macOS side. The daemon
/// owns the codec (`contact.export`/`contact.import`); this file is the UI
/// seam: share a card (.vcf through the share picker), confirm an
/// `idfon://add/` deep link, open a .vcf document, save a card to the system
/// Contacts app, and show the QR form of the link. QR scanning is phone-side:
/// the Mac shows the code for the phone's camera.
/// How a protected contact admits a device — the `auth` block of an add
/// envelope. The approval modal runs it: agent criteria shown, and the
/// admission code redeemed for the sender-bound capability ticket (the
/// `radio-admit.sh` contract, over `redeem`). The code usually rides in the
/// link itself (a per-load one-shot nonce); a `code` is only typed when the
/// envelope left it out.
struct AddAuth: Equatable {
    var kind: String
    var label: String
    var criteria: String?
    var redeemURL: String
    var code: String?
}

enum ContactExchange {
    /// Ticket JSON from an `idfon://add/<base64url>` deep-link payload.
    static func ticketJSON(fromLink payload: String) -> String? {
        decodeLink(payload)?.ticketJSON
    }

    /// A link carries either a contact ticket (legacy) or an envelope
    /// `{ "contact": …, "capability": …, "auth": … }`. A station signs the
    /// capability ticket that admits this device, so one scan both adds the
    /// contact and makes it callable — the add path's only way to deliver a
    /// credential. A protected contact ships `auth` instead: its admission
    /// flow runs in the approval modal (`AddAuth`).
    static func decodeLink(_ payload: String) -> (ticketJSON: String, capabilityJSON: String?, auth: AddAuth?)? {
        var base64 = payload.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let text = String(data: data, encoding: .utf8) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contact = object["contact"] as? [String: Any] else {
            return (text, nil, nil) // legacy: the payload is the ticket itself
        }
        guard let contactData = try? JSONSerialization.data(withJSONObject: contact),
              let contactJSON = String(data: contactData, encoding: .utf8) else { return nil }
        // A ticket is an rcan token string; legacy links embedded a JSON object.
        let capabilityJSON = (object["capability"] as? String)
            ?? (object["capability"] as? [String: Any]).flatMap { capability in
                (try? JSONSerialization.data(withJSONObject: capability))
                    .flatMap { String(data: $0, encoding: .utf8) }
            }
        let auth = (object["auth"] as? [String: Any]).flatMap { auth -> AddAuth? in
            guard let kind = auth["kind"] as? String, let url = auth["url"] as? String else { return nil }
            return AddAuth(
                kind: kind,
                label: (auth["label"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Admission code",
                criteria: (auth["criteria"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                redeemURL: url,
                code: (auth["code"] as? String).flatMap { $0.isEmpty ? nil : $0 })
        }
        return (contactJSON, capabilityJSON, auth)
    }

    /// The peer id a channel contact is keyed by — the ticket's `endpoint_id`,
    /// else the endpoint address's `id` (the rule `-pair` uses).
    static func endpointId(ofTicketJSON ticketJSON: String) -> String? {
        guard let ticket = try? JSONSerialization.jsonObject(with: Data(ticketJSON.utf8)) as? [String: Any] else {
            return nil
        }
        if let id = ticket["endpoint_id"] as? String, !id.isEmpty { return id }
        // A station's card in the add link is a bare endpoint address
        // (`{id, addrs}`), not a ContactTicket — the id is the first field.
        if let id = ticket["id"] as? String, !id.isEmpty { return id }
        guard let address = ticket["endpoint_addr"] as? String,
              let transport = try? JSONSerialization.jsonObject(with: Data(address.utf8)) as? [String: Any] else {
            return nil
        }
        return (transport["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
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
    static func confirmAdd(
        ticketJSON: String,
        capabilityJSON: String? = nil,
        auth: AddAuth? = nil,
        app: AppModel
    ) {
        let name = name(ofTicketJSON: ticketJSON) ?? "Contact"
        let alert = NSAlert()
        alert.messageText = "Add \(name)?"
        alert.informativeText = auth?.criteria ?? "Add this contact to Idfon."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Deny")
        // The rename opportunity, and an admission code field only when the
        // link did not carry one (its auth flow runs below).
        let nameField = NSTextField(string: name)
        nameField.placeholderString = "Name"
        let codeField = auth.flatMap { auth -> NSTextField? in
            guard auth.code == nil else { return nil }
            let field = NSTextField(string: "")
            field.placeholderString = auth.label
            return field
        }
        let stack = NSStackView(views: [nameField] + (codeField.map { [$0] } ?? []))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        alert.accessoryView = stack
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let typed = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let renamed = typed.isEmpty ? name : typed
        let code = codeField?.stringValue
        Task {
            do {
                var credential = capabilityJSON
                if let auth {
                    // Protected: redeem the admission code for the
                    // sender-bound ticket this device presents.
                    credential = try await redeem(auth: auth, code: code, client: app.client)
                }
                if let error = await app.addChannel(name: renamed, ticketJSON: ticketJSON) {
                    await MainActor.run { plainSheet(title: "Contact Failed", message: error) }
                } else if let credential, let peer = endpointId(ofTicketJSON: ticketJSON) {
                    _ = CapabilityTickets.store(credential, for: peer)
                }
            } catch {
                await MainActor.run {
                    plainSheet(
                        title: auth != nil ? "Admission Failed" : "Contact Failed",
                        message: error.localizedDescription)
                }
            }
        }
    }

    /// Redeems an admission code for the sender-bound capability ticket:
    /// `POST {code, subject}` to the envelope's `auth.url`, where the page
    /// allow-lists this device and mints `ticket --subject <peer>` for it
    /// (the `radio-admit.sh` contract, no console round-trip). The code is
    /// the one embedded in the link, else the typed one.
    private static func redeem(auth: AddAuth, code: String?, client: DaemonClient) async throws -> String {
        guard let code = (auth.code ?? code)?.trimmingCharacters(in: .whitespaces), !code.isEmpty else {
            throw NSError(domain: "idfon.add", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "An admission code is required."])
        }
        let selfTicket = try await client.contactTicket()
        guard let subject = endpointId(ofTicketJSON: selfTicket), !subject.isEmpty else {
            throw NSError(domain: "idfon.add", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot read this device's peer id."])
        }
        var request = URLRequest(url: URL(string: auth.redeemURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["code": code, "subject": subject])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ticket = reply["ticket"] as? String, !ticket.isEmpty else {
            throw NSError(domain: "idfon.add", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "The admission code was not accepted."])
        }
        return ticket
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

    /// Exports a card `(vcard, link)`: a saved peer's (`ref`) or an identity's
    /// own (`identity` names the line by id or name; nil = the active one).
    static func export(
        ref: String?, identity: String? = nil, client: DaemonClient = DaemonClient()
    ) async throws -> (vcard: String, link: String) {
        var identity = identity
        if ref == nil, identity == nil {
            identity = (try? await client.identityId()) ?? "default"
        }
        return try await client.contactExport(ref: ref, identity: identity)
    }

    /// Share picker with the card as a temp .vcf. AirDrop lands it in the
    /// receiver's Contacts app; the card's `idfon://add/` URL does the rest.
    static func shareCard(ref: String?, identity: String? = nil, relativeTo view: NSView) {
        Task {
            do {
                let card = try await export(ref: ref, identity: identity)
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
