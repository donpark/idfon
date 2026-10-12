//! Host probe for the on-device director (`cargo run -p idfon-director
//! --features afm --example afm_probe`). Runs real AFM turns on a machine with
//! Apple Intelligence, so the loop's Apple path can be measured without a
//! device.
//!
//!   afm_probe                  three text turns (latency, speak envelopes)
//!   afm_probe <image.png>      one image turn: the image is attached and the
//!                              model is asked what it shows (the check that
//!                              pixels reach the model, not just metadata)
//!   afm_probe <image.png> "q"  the same, with your own question
//!
//! An image turn may take a couple of seconds: the model is started with
//! attachments on a session built for text.

#[cfg(feature = "afm")]
fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if let Some(path) = args.first() {
        image_turn(path, args.get(1).map(String::as_str));
        return;
    }
    text_turns();
}

#[cfg(feature = "afm")]
fn text_turns() {
    let t = std::time::Instant::now();
    let mut d = match idfon_director::Director::afm("You are a short-spoken voice test director.") {
        Ok(d) => d,
        Err(e) => {
            println!("afm unavailable: {e}");
            return;
        }
    };
    println!("new: {:?}", t.elapsed());
    let t = std::time::Instant::now();
    d.prewarm();
    println!("prewarm: {:?}", t.elapsed());
    for prompt in [
        "Use the speak tool to say hello.",
        "Use the speak tool to say that the appointment moved to Thursday at two.",
        "Say goodbye in one short sentence.",
    ] {
        let t = std::time::Instant::now();
        let r = d.turn(prompt);
        println!(
            "turn {:?} ({} ms): envelopes={} trace_steps={}",
            t.elapsed(),
            r.elapsed_ms,
            r.envelopes.len(),
            r.trace().len()
        );
        for e in &r.envelopes {
            println!("   env: {}", e.lines().last().unwrap_or(""));
        }
        let names: Vec<String> = r
            .trace()
            .iter()
            .filter(|t| t.kind == "tool_call")
            .map(|t| t.name.clone().unwrap_or_default())
            .collect();
        println!("   tools: {:?}", names);
    }
}

#[cfg(feature = "afm")]
fn image_turn(path: &str, question: Option<&str>) {
    use base64::Engine as _;
    use idfon_director::turn_input::{Attachment, TurnInput};

    let bytes = match std::fs::read(path) {
        Ok(bytes) => bytes,
        Err(error) => {
            println!("cannot read {path}: {error}");
            return;
        }
    };
    let mime = match path.rsplit('.').next() {
        Some("jpg") | Some("jpeg") => "image/jpeg",
        Some("heic") => "image/heic",
        _ => "image/png",
    };
    let mut d = match idfon_director::Director::afm("You are a short-spoken voice test director.") {
        Ok(d) => d,
        Err(e) => {
            println!("afm unavailable: {e}");
            return;
        }
    };
    let input = TurnInput {
        text: question
            .unwrap_or("What is in this image? Answer in one short sentence.")
            .to_string(),
        references: Vec::new(),
        attachments: vec![Attachment::Image {
            name: "probe.png".to_string(),
            mime: mime.to_string(),
            data: base64::engine::general_purpose::STANDARD.encode(&bytes),
        }],
    };
    // What the model is handed beyond the pixels: one line, so the probe shows
    // the prompt the image rides with.
    println!(
        "prompt: {}",
        input.render(false).lines().next().unwrap_or("")
    );
    let t = std::time::Instant::now();
    let r = d.turn_input(&input);
    println!(
        "image turn {:?} ({} ms): envelopes={}",
        t.elapsed(),
        r.elapsed_ms,
        r.envelopes.len()
    );
    if r.envelopes.is_empty() {
        println!("   (no envelope: the model did not speak)");
    }
    for e in &r.envelopes {
        println!("   env: {}", e.lines().last().unwrap_or(""));
    }
}

#[cfg(not(feature = "afm"))]
fn main() {
    println!("build with --features afm");
}
