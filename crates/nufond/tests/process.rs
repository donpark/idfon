use std::{
    env, fs,
    io::{Read, Write},
    os::unix::net::UnixStream,
    path::PathBuf,
    process::{Child, Command},
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

fn temp_root() -> PathBuf {
    env::temp_dir().join(format!(
        "nufond-process-{}",
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ))
}

fn wait_for_socket(path: &PathBuf) {
    for _ in 0..100 {
        if path.exists() {
            return;
        }
        thread::sleep(Duration::from_millis(50));
    }
    panic!("daemon socket did not appear: {}", path.display());
}

fn request(socket: &PathBuf, method: &str) -> serde_json::Value {
    let mut stream = UnixStream::connect(socket).unwrap();
    let body = serde_json::to_vec(&serde_json::json!({
        "version": 1, "id": method, "method": method, "params": {}
    }))
    .unwrap();
    stream
        .write_all(&(body.len() as u32).to_be_bytes())
        .unwrap();
    stream.write_all(&body).unwrap();
    let mut header = [0; 4];
    stream.read_exact(&mut header).unwrap();
    let mut response = vec![0; u32::from_be_bytes(header) as usize];
    stream.read_exact(&mut response).unwrap();
    serde_json::from_slice(&response).unwrap()
}

fn stop(child: &mut Child) {
    let _ = child.kill();
    let _ = child.wait();
}

#[test]
fn two_independent_daemons_start_with_distinct_iroh_identities() {
    let root = temp_root();
    let first_socket = root.join("first.sock");
    let second_socket = root.join("second.sock");
    let first_data = root.join("first");
    let second_data = root.join("second");
    fs::create_dir_all(&root).unwrap();
    let binary = env!("CARGO_BIN_EXE_nufond");
    let mut first = Command::new(binary)
        .args([
            "--socket",
            first_socket.to_str().unwrap(),
            "--data-dir",
            first_data.to_str().unwrap(),
            "--transport",
            "iroh",
        ])
        .spawn()
        .unwrap();
    let mut second = Command::new(binary)
        .args([
            "--socket",
            second_socket.to_str().unwrap(),
            "--data-dir",
            second_data.to_str().unwrap(),
            "--transport",
            "iroh",
        ])
        .spawn()
        .unwrap();
    wait_for_socket(&first_socket);
    wait_for_socket(&second_socket);

    let first_context = request(&first_socket, "context");
    let second_context = request(&second_socket, "context");
    assert!(first_context["ok"].as_bool().unwrap());
    assert!(second_context["ok"].as_bool().unwrap());
    let first_id = first_context["result"]["identity"]["endpoint_id"]
        .as_str()
        .unwrap();
    let second_id = second_context["result"]["identity"]["endpoint_id"]
        .as_str()
        .unwrap();
    assert_ne!(first_id, second_id);
    assert_eq!(request(&first_socket, "status")["result"]["ready"], true);
    assert_eq!(request(&second_socket, "status")["result"]["ready"], true);

    stop(&mut first);
    stop(&mut second);
    assert!(first_data.join("state.json").is_file());
    assert!(second_data.join("state.json").is_file());
    fs::remove_dir_all(root).unwrap();
}
