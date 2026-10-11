#[cfg(feature = "afm")]
fn main() {
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
        println!("turn {:?} ({} ms): envelopes={} trace_steps={}", t.elapsed(), r.elapsed_ms, r.envelopes.len(), r.trace.len());
        for e in &r.envelopes { println!("   env: {}", e.lines().last().unwrap_or("")); }
        let names: Vec<String> = r.trace.iter().filter(|t| t.kind=="tool_call").map(|t| t.name.clone().unwrap_or_default()).collect();
        println!("   tools: {:?}", names);
    }
}

#[cfg(not(feature = "afm"))]
fn main() {
    println!("build with --features afm");
}
