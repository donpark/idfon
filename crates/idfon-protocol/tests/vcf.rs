use idfon_protocol::vcf::{contact_ticket_vcard, vcard_contact_tickets};
use idfon_protocol::ContactTicket;

fn ticket() -> ContactTicket {
    ContactTicket {
        version: 1,
        account_id: "account-1".into(),
        endpoint_id: "endpoint-1".into(),
        // Long enough to force folded lines.
        endpoint_addr: format!(
            r#"{{"node_id":"abc","relay_url":"https://relay.example.org","direct_addresses":["192.0.2.1:1234","[2001:db8::1]:1234"],"secret":"{}"}}"#,
            "x".repeat(200)
        ),
        label: Some("Ada; Lovelace, Jr\nEsq".into()),
        device_class: Some("phone".into()),
        capabilities: vec!["chat".into(), "live_audio".into()],
    }
}

#[test]
fn round_trips_folding_escaping_and_json() {
    let original = ticket();
    let vcard = contact_ticket_vcard(&original);
    let parsed = vcard_contact_tickets(&vcard).expect("round trip");
    assert_eq!(parsed, vec![original]);
}

#[test]
fn folds_long_lines_under_75_octets() {
    let vcard = contact_ticket_vcard(&ticket());
    assert!(vcard.split("\r\n").all(|line| {
        line.starts_with(' ') || line.len() <= 75
    }));
}

#[test]
fn imports_many_cards_and_skips_foreign_ones() {
    let mut text = contact_ticket_vcard(&ticket());
    text.push_str("BEGIN:VCARD\r\nVERSION:3.0\r\nFN:No Ticket\r\nN:;No Ticket;;;\r\nEND:VCARD\r\n");
    let mut second = ticket();
    second.account_id = "account-2".into();
    text.push_str(&contact_ticket_vcard(&second));
    let parsed = vcard_contact_tickets(&text).expect("mixed import");
    assert_eq!(parsed.len(), 2);
    assert_eq!(parsed[0].account_id, "account-1");
    assert_eq!(parsed[1].account_id, "account-2");
}

#[test]
fn export_falls_back_to_the_account_id_for_the_name() {
    let mut card = ticket();
    card.label = None;
    assert!(contact_ticket_vcard(&card).contains("FN:account-1"));
}

#[test]
fn fn_wins_over_the_ticket_label_on_import() {
    let mut card = ticket();
    card.label = Some("Old Name".into());
    let vcard = contact_ticket_vcard(&card).replace("FN:Old Name", "FN:New Name");
    let parsed = vcard_contact_tickets(&vcard).expect("renamed card");
    assert_eq!(parsed[0].label.as_deref(), Some("New Name"));
}

#[test]
fn rejects_a_file_without_idfon_cards() {
    let text = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:No Ticket\r\nEND:VCARD\r\n";
    assert!(vcard_contact_tickets(text).is_err());
}

/// Simulates an AirDrop -> Contacts round-trip: the app drops the unknown X-
/// property (with its folded continuation lines) but keeps standard fields.
fn contacts_strips_x_property(card: &str) -> String {
    let mut kept = Vec::new();
    let mut dropping = false;
    for line in card.split("\r\n") {
        if line.starts_with(' ') {
            if !dropping {
                kept.push(line);
            }
        } else {
            dropping = line.starts_with("X-IDFON-TICKET:");
            if !dropping {
                kept.push(line);
            }
        }
    }
    kept.join("\r\n")
}

#[test]
fn export_carries_the_deep_link() {
    assert!(contact_ticket_vcard(&ticket()).contains("URL:idfon://add/"));
}

#[test]
fn import_survives_contacts_stripping_the_x_property() {
    let stripped = contacts_strips_x_property(&contact_ticket_vcard(&ticket()));
    assert!(!stripped.contains("X-IDFON-TICKET"));
    let parsed = vcard_contact_tickets(&stripped).expect("URL-only card");
    assert_eq!(parsed, vec![ticket()]);
}

#[test]
fn url_only_card_still_takes_the_name_from_fn() {
    let mut card = ticket();
    card.label = Some("Old Name".into());
    let stripped = contacts_strips_x_property(&contact_ticket_vcard(&card))
        .replace("FN:Old Name", "FN:New Name");
    let parsed = vcard_contact_tickets(&stripped).expect("renamed URL card");
    assert_eq!(parsed[0].label.as_deref(), Some("New Name"));
}

#[test]
fn garbage_in_the_url_slot_is_skipped() {
    let text = "BEGIN:VCARD\r\nVERSION:3.0\r\nFN:Bad\r\nURL:idfon://add/not-base64!!\r\nEND:VCARD\r\n";
    assert!(vcard_contact_tickets(text).is_err());
}
