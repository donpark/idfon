import AVFoundation
import Contacts
import CoreImage
import UIKit

/// vCard contact exchange (docs/contact-exchange.md). The daemon owns the
/// codec (`contact.export`/`contact.import`); this file is the UI seam for
/// giving a card (share-sheet .vcf, QR, Save to Contacts) and receiving one
/// (`idfon://add/` deep link, .vcf document open, QR scan).
///
/// NameDrop itself is closed to third-party apps, so the AirDrop->Contacts
/// route is the substitute: the exported card carries the ticket in a
/// standard `URL` property (`idfon://add/<base64url>`) that survives the
/// Contacts round-trip and deep-links back here.
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

    /// Confirm-and-add for a received ticket. Mirrors the Add Contact flow
    /// (peer.add + the default chat grants).
    static func confirmAdd(
        ticketJSON: String,
        capabilityJSON: String? = nil,
        auth: AddAuth? = nil,
        from viewController: UIViewController,
        client: IdfonClient = IdfonClient(),
        onAdded: @escaping () -> Void = {}
    ) {
        let name = name(ofTicketJSON: ticketJSON) ?? "Contact"
        let alert = UIAlertController(
            title: "Add \(name)?",
            message: auth?.criteria ?? "Add this contact to Idfon.", preferredStyle: .alert)
        alert.addTextField { field in
            field.text = name
            field.placeholder = "Name"
        }
        // An admission code field only when the link did not carry one.
        if let auth, auth.code == nil {
            alert.addTextField { field in
                field.placeholder = auth.label
                field.autocapitalizationType = .allCharacters
            }
        }
        alert.addAction(UIAlertAction(title: "Deny", style: .cancel))
        alert.addAction(UIAlertAction(title: "Add", style: .default) { _ in
            // The rename opportunity: the typed name wins over the card label.
            let typed = alert.textFields?.first?.text?
                .trimmingCharacters(in: .whitespaces)
            let renamed = (typed?.isEmpty == false ? typed : nil) ?? name
            let code = auth.flatMap { $0.code ?? alert.textFields?.last?.text }
            Task {
                do {
                    var credential = capabilityJSON
                    if let auth {
                        // Protected: the auth flow — redeem the admission code
                        // for the sender-bound ticket this device presents.
                        credential = try await redeem(auth: auth, code: code, client: client)
                    }
                    let identity = (try? await client.identityId()) ?? "default"
                    try await client.addChannel(name: renamed, ticketJSON: ticketJSON, identity: identity)
                    if let credential, let peer = endpointId(ofTicketJSON: ticketJSON) {
                        _ = CapabilityTickets.store(credential, for: peer)
                    }
                    await MainActor.run { onAdded() }
                } catch {
                    await MainActor.run {
                        let failure = UIAlertController(
                            title: auth != nil ? "Admission Failed" : "Contact failed",
                            message: error.localizedDescription,
                            preferredStyle: .alert)
                        failure.addAction(UIAlertAction(title: "OK", style: .default))
                        topPresenter(from: viewController).present(failure, animated: true)
                    }
                }
            }
        })
        topPresenter(from: viewController).present(alert, animated: true)
    }

    /// Redeems an admission code for the sender-bound capability ticket:
    /// `POST {code, subject}` to the envelope's `auth.url`, where the page
    /// allow-lists this device and mints `ticket --subject <peer>` for it
    /// (the `radio-admit.sh` contract, no console round-trip). The code is
    /// the one embedded in the link, else the typed one.
    private static func redeem(auth: AddAuth, code: String?, client: IdfonClient) async throws -> String {
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

    /// Imports a received .vcf (document open) via `contact.import`.
    static func importVCard(
        text: String,
        from viewController: UIViewController,
        client: IdfonClient = IdfonClient(),
        onAdded: @escaping () -> Void = {}
    ) {
        Task {
            do {
                let names = try await client.importVCard(text: text)
                await MainActor.run {
                    onAdded()
                    let message = names.isEmpty
                        ? "No idfon contact cards in this file."
                        : "Added \(names.joined(separator: ", "))."
                    let alert = UIAlertController(title: "Import Contact", message: message, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .default))
                    topPresenter(from: viewController).present(alert, animated: true)
                }
            } catch {
                await MainActor.run {
                    let failure = UIAlertController(
                        title: "Import failed", message: error.localizedDescription, preferredStyle: .alert)
                    failure.addAction(UIAlertAction(title: "OK", style: .default))
                    topPresenter(from: viewController).present(failure, animated: true)
                }
            }
        }
    }

    /// Exports a card `(vcard, link)`: a saved peer's (`ref`) or an identity's
    /// own (`identity` names the line by id or name; nil = the active one).
    static func export(
        ref: String?, identity: String? = nil, client: IdfonClient = IdfonClient()
    ) async throws -> (vcard: String, link: String) {
        var identity = identity
        if ref == nil, identity == nil {
            identity = (try? await client.identityId()) ?? "default"
        }
        return try await client.contactExport(ref: ref, identity: identity)
    }

    /// Share sheet with the card as a temp .vcf. AirDrop lands it in the
    /// receiver's Contacts app; the card's `idfon://add/` URL does the rest.
    static func shareCard(
        ref: String?, identity: String? = nil, from viewController: UIViewController,
        sourceView: UIView? = nil
    ) {
        Task {
            do {
                let card = try await export(ref: ref, identity: identity)
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("idfon-contact.vcf")
                try card.vcard.write(to: url, atomically: true, encoding: .utf8)
                await MainActor.run {
                    let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                    if let popover = activity.popoverPresentationController {
                        let source = sourceView ?? viewController.view
                        popover.sourceView = source
                        popover.sourceRect = CGRect(x: source?.bounds.midX ?? 0, y: source?.bounds.midY ?? 0, width: 1, height: 1)
                    }
                    topPresenter(from: viewController).present(activity, animated: true)
                }
            } catch {
                await MainActor.run {
                    let failure = UIAlertController(
                        title: "Export failed", message: error.localizedDescription, preferredStyle: .alert)
                    failure.addAction(UIAlertAction(title: "OK", style: .default))
                    topPresenter(from: viewController).present(failure, animated: true)
                }
            }
        }
    }

    /// Saves the card behind an `idfon://add/` link into the system Contacts
    /// app (name + URL), the handoff point for AirDrop/NameDrop onward.
    static func saveToSystemContacts(link: String) throws {
        let payload = String(link.dropFirst("idfon://add/".count))
        let name = ticketJSON(fromLink: payload).flatMap(name(ofTicketJSON:))
            ?? "Idfon Contact"
        let contact = CNMutableContact()
        contact.givenName = name
        contact.urlAddresses = [CNLabeledValue(label: "idfon", value: link as NSString)]
        let request = CNSaveRequest()
        request.add(contact, toContainerWithIdentifier: nil)
        try CNContactStore().execute(request)
    }

    /// QR image for a link (what the other phone scans).
    static func qrImage(link: String) -> UIImage? {
        guard let data = link.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else {
            return nil
        }
        return UIImage(ciImage: output)
    }

    /// Receives a scanned QR payload (an `idfon://add/...` link or bare payload).
    static func handleScan(
        _ raw: String, from viewController: UIViewController,
        client: IdfonClient = IdfonClient(), onAdded: @escaping () -> Void = {}
    ) {
        var payload = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: payload), case .add(let link)? = IdfonURL(url) {
            payload = link
        }
        guard let link = decodeLink(payload) else {
            let alert = UIAlertController(
                title: "Not a Contact Code", message: "Scan an idfon contact QR code.",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            topPresenter(from: viewController).present(alert, animated: true)
            return
        }
        // Keep the envelope: a station's QR carries the capability ticket (and
        // protected contacts their admission flow), exactly like a tapped link.
        confirmAdd(
            ticketJSON: link.ticketJSON, capabilityJSON: link.capabilityJSON, auth: link.auth,
            from: viewController, client: client, onAdded: onAdded)
    }

    /// The topmost presented controller (alerts must present from whatever is
    /// actually visible).
    private static func topPresenter(from viewController: UIViewController) -> UIViewController {
        var top = viewController
        while let next = top.presentedViewController { top = next }
        return top
    }
}

/// "My Card": the give side of the NameDrop substitute. Shows the
/// `idfon://add/` QR for this identity's card; Share exports the .vcf; Save
/// writes it to the system Contacts app.
final class MyCardViewController: UIViewController {
    private let imageView = UIImageView()
    private let caption = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "My Card"
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close, target: self, action: #selector(close))
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "square.and.arrow.up"), style: .plain,
            target: self, action: #selector(share))

        imageView.contentMode = .scaleAspectFit
        caption.font = .preferredFont(forTextStyle: .footnote)
        caption.textColor = .secondaryLabel
        caption.textAlignment = .center
        caption.numberOfLines = 0
        caption.text = "Let someone scan this to add you as a contact."

        let saveButton = UIButton(configuration: .filled())
        saveButton.setTitle("Save to Contacts", for: .normal)
        saveButton.addTarget(self, action: #selector(save), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [imageView, caption, saveButton])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            imageView.widthAnchor.constraint(equalToConstant: 240),
            imageView.heightAnchor.constraint(equalTo: imageView.widthAnchor),
        ])

        Task {
            do {
                let card = try await ContactExchange.export(ref: nil)
                await MainActor.run { self.imageView.image = ContactExchange.qrImage(link: card.link) }
            } catch {
                await MainActor.run {
                    self.caption.text = error.localizedDescription
                }
            }
        }
    }

    @objc private func close() { dismiss(animated: true) }

    @objc private func share() {
        ContactExchange.shareCard(ref: nil, from: self, sourceView: view)
    }

    @objc private func save() {
        Task {
            do {
                let card = try await ContactExchange.export(ref: nil)
                try ContactExchange.saveToSystemContacts(link: card.link)
                await MainActor.run {
                    let alert = UIAlertController(
                        title: "Saved", message: "The card is in your Contacts app.",
                        preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .default))
                    self.present(alert, animated: true)
                }
            } catch {
                await MainActor.run {
                    let alert = UIAlertController(
                        title: "Save failed", message: error.localizedDescription,
                        preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .default))
                    self.present(alert, animated: true)
                }
            }
        }
    }
}

/// Camera QR scanner for contact codes; hands the raw code string to `onCode`.
final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private let preview = AVCaptureVideoPreviewLayer()
    private var found = false
    var onCode: ((String) -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Scan Contact Code"
        view.backgroundColor = .black
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(close))
        preview.session = session
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                if granted {
                    self?.configure()
                } else {
                    self?.showCameraDenied()
                }
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning { session.stopRunning() }
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            showCameraDenied()
            return
        }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            showCameraDenied()
            return
        }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }
    }

    private func showCameraDenied() {
        let alert = UIAlertController(
            title: "Camera Unavailable",
            message: "Allow camera access in Settings to scan contact codes.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.close()
        })
        present(alert, animated: true)
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !found,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue else { return }
        found = true
        session.stopRunning()
        let onCode = self.onCode
        dismiss(animated: true) { onCode?(value) }
    }

    @objc private func close() { dismiss(animated: true) }
}
