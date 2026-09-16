use idfon_protocol::{IncomingCallMode, Peer, PeerDevice};

fn device(id: &str, addr: Option<&str>) -> PeerDevice {
    PeerDevice {
        endpoint_id: id.into(),
        endpoint_addr: addr.map(str::to_owned),
        label: None,
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
            device("primary", Some("dupe-addr")),
            device("phone", Some("phone-addr")),
            device("no-address", None),
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
fn knows_endpoint_matches_devices_only() {
    let peer = sample();
    assert!(peer.knows_endpoint("primary"));
    assert!(peer.knows_endpoint("phone"));
    assert!(peer.knows_endpoint("no-address"));
    assert!(!peer.knows_endpoint("stranger"));
}
