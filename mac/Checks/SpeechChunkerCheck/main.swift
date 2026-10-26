// Runnable check for `SpeechChunker` (not part of the app target).
// SpeechChunker is Foundation-only, so this runs on the host with plain swiftc:
//
//   swiftc -o /tmp/sccheck mac/Sources/Idfon/SpeechChunker.swift \
//     mac/Checks/SpeechChunkerCheck/main.swift
//   /tmp/sccheck
//
// The cases are tyger-s2s's chunker invariants (mouth/chunker.py).
// Prints "ALL OK" or the first failing assertion (exit 1).
import Foundation

func check(_ cond: Bool, _ msg: String) {
    if !cond { print("FAIL:", msg); exit(1) } else { print("ok:", msg) }
}

// In-word punctuation never splits.
for token in ["0.50", "3,000", "1:30", "example.com"] {
    let text = "I mean " + token + " exactly and that is what we agreed"
    let joined = SpeechChunker.chunks(text).joined(separator: " ")
    check(joined.contains(token), "token intact: \(token)")
}

// Spaced hyphen splits; unspaced never does.
check(SpeechChunker.chunks("The Las-Palmas trip was fine and we talked all day").joined(separator: " ")
        .contains("Las-Palmas"), "Las-Palmas intact");
do {
    let text = "It was well-known at the office and everyone agreed about it"
    check(SpeechChunker.chunks(text).joined(separator: " ").contains("well-known"), "well-known intact")
}

// Abbreviations, initials and dotted acronyms are not sentence ends.
for text in [
    "Mr. Smith went to the store and bought milk yesterday",
    "J. K. Rowling wrote the books and everyone read them",
    "We flew via the U.S. route and it took forever yesterday",
] {
    let first = SpeechChunker.chunks(text).first ?? ""
    check(!first.hasSuffix("."), "abbrev does not end a chunk: \(first.suffix(8))")
}

// MIN_CHARS: short text goes out whole, never fragmented.
check(SpeechChunker.chunks("Hi there.").count == 1, "short text is one chunk")

// Whole sentences are the chunk unit (first_chunk: sentence).
do {
    let text = "One sentence here goes first and it is long enough. And the second sentence follows after."
    let parts = SpeechChunker.chunks(text)
    check(parts.count == 2, "two sentences, two chunks (\(parts.count))")
    check(parts[0].hasSuffix("."), "chunk one is a whole sentence")
}

// SENT_MAX: a run-on flushes on a space.
do {
    let runOn = Array(repeating: "word", count: 120).joined(separator: " ")
    let first = SpeechChunker.chunks(runOn).first ?? ""
    check(first.count <= SpeechChunker.sentMax, "run-on flushes at SENT_MAX (\(first.count))")
}

// say_clean: speakable characters survive, tags do not.
check(SpeechChunker.sayClean("José went to Zürich") == "José went to Zürich", "accents survive")
check(SpeechChunker.sayClean("hello — world") == "hello, world", "clause dash -> comma")
check(SpeechChunker.sayClean("5 – 10") == "5-10", "digit range keeps the hyphen")
check(SpeechChunker.sayClean("that is 50% fine, ok") == "that is 50% fine, ok", "% survives")
check({
    let cleaned = SpeechChunker.sayClean("I’d say _yes_ [laugh]")
    return cleaned.contains("I’d") && cleaned.contains("yes") && !cleaned.contains("[")
}(), "apostrophe kept, tag glyphs dropped")

// next_chunk streaming shape: nothing is ready until a boundary closes.
check(SpeechChunker.nextChunk("The beginning of a sen") == nil, "incomplete text stays pending")


// ChunkFeeder: the incremental mouth feed over a growing text (speech-unit
// partials). Chunks close in order as the text grows; the tail speaks at
// finish; a divergent stream falls back to the final whole.
do {
    var feeder = ChunkFeeder()
    var spoken: [String] = []
    let full = "I looked up the time in Tokyo, and it is three in the afternoon there now. "
        + "Would you like me to set a reminder as well, or is there anything else?"
    for end in stride(from: 20, through: full.count, by: 37) {
        spoken += feeder.feed(String(full.prefix(end)))
    }
    spoken += feeder.finish(full)
    check(spoken.joined(separator: " ").replacingOccurrences(of: "  ", with: " ")
            .contains("I looked up the time in Tokyo"), "feeder speaks the stream")
    check(spoken.allSatisfy { !$0.isEmpty }, "feeder emits no empty chunks")
    check(spoken.count >= 2, "feeder closed chunks incrementally (\(spoken.count))")
}
do {
    // Divergence: the spoken form replaces what streamed; finish speaks it whole.
    var feeder = ChunkFeeder()
    check(feeder.feed("Let me look into that.").count <= 1, "short stream stays pending-ish")
    check(feeder.feed("The time in Tokyo is three PM.").isEmpty, "divergent stream stops the mouth")
    let out = feeder.finish("The time in Tokyo is three PM.")
    check(out.contains("The time in Tokyo is three PM."), "divergent finish speaks the final whole")
}
do {
    // No partials at all (an old holder): the final speaks whole.
    var feeder = ChunkFeeder()
    let out = feeder.finish("A plain reply with no streaming.")
    check(out.contains("A plain reply with no streaming."), "finish with no feed speaks whole")
}
print("ALL OK")
