import Foundation

/// A capability ticket as the push ring presents it, with the fields the ring
/// binds. Pure parsing/derivation so the host check can pin the #52 seam:
/// `caller_id` must come from the ticket itself — a contact ticket binds it as
/// `subject`, a self-issued statement as `issuer`, which is also the
/// `sender.peer_id` message events carry. The identity key and the iroh
/// endpoint id are different ids (#56); any other derivation breaks the edge's
/// ticket checks and the callee's push/envelope dedupe.
struct RingTicket {
    let raw: String
    let issuer: String
    let subject: String?

    /// The `caller_id` the ring carries.
    var callerId: String { subject ?? issuer }

    init?(json: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let issuer = object["issuer"] as? String, !issuer.isEmpty
        else { return nil }
        self.raw = json
        self.issuer = issuer
        self.subject = (object["subject"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The ticket to present: the stored contact ticket (the callee's
    /// statement about us) when it binds a subject, otherwise the self-issued
    /// statement.
    static func presentation(contact: RingTicket?, issued: RingTicket?) -> RingTicket? {
        if let contact = contact, contact.subject != nil { return contact }
        return issued
    }
}
