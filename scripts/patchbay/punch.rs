// Minimal STUN-like rendezvous + UDP hole-punch probe, std only.
// rv:   binds --port, pairs the first two registered peers, reports their mapped addr.
// peer: registers, gets the peer's mapped addr, punches, counts pongs.
use std::env;
use std::net::{SocketAddr, UdpSocket};
use std::time::{Duration, Instant};

fn arg(name: &str, default: &str) -> String {
    let a: Vec<String> = env::args().collect();
    a.iter()
        .position(|x| x == name)
        .and_then(|i| a.get(i + 1).cloned())
        .unwrap_or_else(|| default.to_string())
}

fn rv(port: u16, seconds: u64) -> std::io::Result<()> {
    let sock = UdpSocket::bind(("0.0.0.0", port))?;
    sock.set_read_timeout(Some(Duration::from_millis(200)))?;
    let deadline = Instant::now() + Duration::from_secs(seconds);
    let mut seen: Vec<(String, SocketAddr)> = Vec::new();
    let mut buf = [0u8; 256];
    while Instant::now() < deadline {
        let (n, src) = match sock.recv_from(&mut buf) {
            Ok(v) => v,
            Err(_) => continue,
        };
        let msg = String::from_utf8_lossy(&buf[..n]).to_string();
        let mut it = msg.split_whitespace();
        let kind = it.next().unwrap_or("");
        let name = it.next().unwrap_or("").to_string();
        if name.is_empty() {
            continue;
        }
        match seen.iter_mut().find(|(n, _)| *n == name) {
            Some(e) => e.1 = src,
            None => seen.push((name.clone(), src)),
        }
        let reply = match kind {
            "HELLO" => format!("YOURS {}", src),
            "PEER" => match seen.iter().find(|(n, _)| *n != name) {
                Some((_, a)) => format!("PEER {}", a),
                None => "WAIT".to_string(),
            },
            _ => continue,
        };
        let _ = sock.send_to(reply.as_bytes(), src);
    }
    Ok(())
}

fn peer(port: u16, rv_addr: SocketAddr, me: &str, seconds: u64) -> std::io::Result<()> {
    let sock = UdpSocket::bind(("0.0.0.0", port))?;
    sock.set_read_timeout(Some(Duration::from_millis(100)))?;
    let mut buf = [0u8; 256];

    let mut mapped = String::from("?");
    let mut peer_addr: Option<SocketAddr> = None;
    let step_deadline = Instant::now() + Duration::from_secs(8);
    while Instant::now() < step_deadline && (mapped == "?" || peer_addr.is_none()) {
        let probe = if mapped == "?" {
            format!("HELLO {me}")
        } else {
            format!("PEER {me}")
        };
        let _ = sock.send_to(probe.as_bytes(), rv_addr);
        match sock.recv_from(&mut buf) {
            Ok((n, _)) => {
                let msg = String::from_utf8_lossy(&buf[..n]).to_string();
                if let Some(rest) = msg.strip_prefix("YOURS ") {
                    mapped = rest.trim().to_string();
                    println!("MAPPED {mapped}");
                } else if let Some(rest) = msg.strip_prefix("PEER ") {
                    if let Ok(a) = rest.trim().parse::<SocketAddr>() {
                        peer_addr = Some(a);
                    }
                }
            }
            Err(_) => {}
        }
        std::thread::sleep(Duration::from_millis(150));
    }
    println!("PEERADDR {peer_addr:?}");

    let punch_deadline = Instant::now() + Duration::from_secs(seconds);
    let mut sent = 0u32;
    let mut pongs = 0u32;
    let mut pending: Vec<(u32, Instant)> = Vec::new();
    let mut rtts: Vec<Duration> = Vec::new();
    let mut seq = 0u32;
    let mut last_send = Instant::now() - Duration::from_secs(1);
    while Instant::now() < punch_deadline {
        if let Some(p) = peer_addr {
            if last_send.elapsed() >= Duration::from_millis(200) {
                seq += 1;
                let _ = sock.send_to(format!("PING {seq}").as_bytes(), p);
                pending.push((seq, Instant::now()));
                sent += 1;
                last_send = Instant::now();
            }
        }
        let (n, src) = match sock.recv_from(&mut buf) {
            Ok(v) => v,
            Err(_) => continue,
        };
        let msg = String::from_utf8_lossy(&buf[..n]).to_string();
        if let Some(rest) = msg.strip_prefix("PING ") {
            if Some(src) == peer_addr {
                let _ = sock.send_to(format!("PONG {}", rest.trim()).as_bytes(), src);
            }
        } else if let Some(rest) = msg.strip_prefix("PONG ") {
            if let Ok(s) = rest.trim().parse::<u32>() {
                if let Some(i) = pending.iter().position(|(q, _)| *q == s) {
                    let (_, t) = pending.remove(i);
                    rtts.push(t.elapsed());
                    pongs += 1;
                }
            }
        }
    }
    let min_ms = rtts.iter().min().map(|d| format!("{:.1}", d.as_secs_f64() * 1000.0));
    let avg_ms = if rtts.is_empty() {
        None
    } else {
        Some(format!(
            "{:.1}",
            rtts.iter().map(|d| d.as_secs_f64()).sum::<f64>() / rtts.len() as f64 * 1000.0
        ))
    };
    println!(
        "RESULT name={me} mapped={mapped} sent={sent} pongs={pongs} min_ms={} avg_ms={}",
        min_ms.unwrap_or_else(|| "none".into()),
        avg_ms.unwrap_or_else(|| "none".into())
    );
    Ok(())
}

fn main() {
    let mode = arg("--mode", "peer");
    let port: u16 = arg("--port", "7000").parse().unwrap();
    let seconds: u64 = arg("--seconds", "6").parse().unwrap();
    let res = if mode == "rv" {
        rv(port, seconds)
    } else {
        let rv_addr: SocketAddr = arg("--rv", "127.0.0.1:7000").parse().unwrap();
        let me = arg("--name", "peer");
        peer(port, rv_addr, &me, seconds)
    };
    if let Err(e) = res {
        eprintln!("error: {e}");
        std::process::exit(1);
    }
}
