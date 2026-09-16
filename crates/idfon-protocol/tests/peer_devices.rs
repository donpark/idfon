use idfon_protocol::{IncomingCallMode, Peer, PeerDevice};

fn device(id: &str, addr: Option<&str>, class: Option<&str>) -> PeerDevice {
    PeerDevice {
        endpoint_id: id.into(),
        endpoint_addr: addr.map(str::to_owned),
        label: None,
        device_class: class.map(str::to_owned),
        capabilities: vec![],
    }
}

fn sample() -> Peer {
    Peer {
        id: "account".into(),
        identity: "default".into(),
        name: "Alice".into(),
        endpoint_id: Some("primary".into()),
        endpoint_addr: Some("primary-addr".into()),
        devices: vec![
            device("primary", Some("dupe-addr"), Some("desktop")),
            device("phone", Some("phone-addr"), Some("mobile")),
            device("no-address", None, Some("mobile")),
        ],
        aliases: vec![],
        call_mode: IncomingCallMode::default(),
    }
}

#[test]
fn dial_targets_primary_first_deduped_addressed() {
    assert_eq!(
        sample().dial_targets(),
        vec![
            ("primary".to_string(), "primary-addr".to_string()),
            ("phone".to_string(), "phone-addr".to_string()),
        ]
    );
}

#[test]
fn delivery_policy_selects_requested_devices() {
    use idfon_protocol::{DeliveryMode, DeliveryPolicy};

    let peer = sample();
    let mobile = DeliveryPolicy {
        mode: DeliveryMode::All,
        device_class: Some("mobile".into()),
        ..Default::default()
    };
    assert_eq!(
        peer.dial_targets_with(Some(&mobile)),
        vec![("phone".into(), "phone-addr".into())]
    );

    let endpoint = DeliveryPolicy {
        mode: DeliveryMode::One,
        endpoint_ids: vec!["phone".into()],
        ..Default::default()
    };
    assert_eq!(
        peer.dial_targets_with(Some(&endpoint)),
        vec![("phone".into(), "phone-addr".into())]
    );
}

#[test]
fn knows_endpoint_matches_devices_only() {
    let peer = sample();
    assert!(peer.knows_endpoint("primary"));
    assert!(peer.knows_endpoint("phone"));
    assert!(peer.knows_endpoint("no-address"));
    assert!(!peer.knows_endpoint("stranger"));
}
