// Runnable check for `MessageKind.parse` (not part of the app target).
// Models.swift is Foundation-only, so this runs on the host with plain swiftc:
//
//   swiftc -o /tmp/mkpcheck mac/Sources/Idfon/Models.swift \
//     mac/Sources/Idfon/Artifact.swift \
//     mac/Checks/MessageKindParseCheck/main.swift
//   /tmp/mkpcheck
//
// Prints "ALL OK" or the first failing assertion (exit 1).
import Foundation

func check(_ cond: Bool, _ msg: String) { if !cond { print("FAIL:", msg); exit(1) } else { print("ok:", msg) } }

func isText(_ kind: MessageKind) -> Bool { if case .text = kind { return true } else { return false } }

// Models.swift's `Event` needs the type/conformance; the check never decodes one.
struct AnyEncodable: Decodable { let value: Any
    init(from decoder: Decoder) throws { value = NSNull() }
}

check(isText(MessageKind.parse("hello")), "plain text passes through")
check(isText(MessageKind.parse("IDFON-RECORDING/1\n")), "recording envelope without a ticket falls back to text")
check(isText(MessageKind.parse("IDFON-FILE/1\nname=x\n")), "file envelope without a ticket falls back to text")

let fileEnvelope = """
IDFON-FILE/1
id=abc
name=Archive.zip
size=12345
sender_id=me
ticket=tkt-1
"""
if case .file(let ticket, let name, let sizeBytes) = MessageKind.parse(fileEnvelope) {
    check(ticket == "tkt-1", "file ticket")
    check(name == "Archive.zip", "file name")
    check(sizeBytes == 12345, "file size")
} else {
    check(false, "file envelope parses as .file")
}

// Values split on the first `=`, so a name may contain one.
if case .file(_, let name, _) = MessageKind.parse("IDFON-FILE/1\nname=a=b.txt\nticket=t\n") {
    check(name == "a=b.txt", "value keeps later '=': \(name)")
} else {
    check(false, "name containing '=' parses")
}

let recordingEnvelope = """
IDFON-RECORDING/1
id=abc
codec=pcm
sample_rate=16000
duration_ms=2500
sender_id=me
ticket=tkt-2
"""
if case .recording(let ticket, let durationMs) = MessageKind.parse(recordingEnvelope) {
    check(ticket == "tkt-2", "recording ticket")
    check(durationMs == 2500, "recording duration")
} else {
    check(false, "recording envelope parses as .recording")
}

// Artifact and reference envelopes (see docs/idfon-artifacts.md).
let artifactEnvelope = "IDFON-ARTIFACT/1\n" + """
{"artifact_id":"art-1","kind":"data","mime":"application/json","title":"Q3","size_bytes":42,"blob_ticket":"tkt","created_at":"2026-09-29T00:00:00Z"}
"""
if case .artifact(let artifact) = MessageKind.parse(artifactEnvelope) {
    check(artifact.artifactId == "art-1", "artifact id")
    check(artifact.kind == .data, "artifact kind")
    check(artifact.blobTicket == "tkt", "artifact ticket")
} else {
    check(false, "artifact envelope parses as .artifact")
}

let referenceEnvelope = "IDFON-REF/1\n" + """
{"text":"what is this?","refs":[{"artifact_id":"art-1","blob_ticket":"tkt-9","selector":{"type":"region","x":0.1,"y":0.2,"width":0.3,"height":0.4}}]}
"""
if case .reference(let reference) = MessageKind.parse(referenceEnvelope) {
    check(reference.refs.count == 1, "one reference")
    check(reference.refs[0].blobTicket == "tkt-9", "reference carries the ticket")
    if case .region(let x, _, _, _, _) = reference.refs[0].selector {
        check(abs(x - 0.1) < 1e-9, "region x")
    } else {
        check(false, "region selector")
    }
} else {
    check(false, "reference envelope parses as .reference")
}

// A reply can be text plus a trailing envelope; MessageBody splits them.
let combined = "Here is your summary.\nIDFON-ARTIFACT/1\n"
    + """
{"artifact_id":"art-2","kind":"document","mime":"text/markdown","title":"s.md","size_bytes":1,"blob_ticket":"t","created_at":"2026-09-29T00:00:00Z"}
"""
let split = MessageBody.parse(combined)
check(split.text?.hasPrefix("Here is your summary") == true, "preamble kept")
check(split.envelopes.count == 1, "one embedded envelope")
if case .artifact(let embedded) = MessageKind.parse(split.envelopes[0]) {
    check(embedded.artifactId == "art-2", "embedded artifact")
} else {
    check(false, "embedded artifact parses")
}
let plainSplit = MessageBody.parse("just text")
check(plainSplit.text == "just text" && plainSplit.envelopes.isEmpty, "plain text unsplit")

print("ALL OK")
