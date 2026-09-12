// Runnable check for `MessageKind.parse` (not part of the Xcode target).
// Models.swift is Foundation-only, so this compiles and runs on the host —
// no simulator needed:
//
//   swiftc -o /tmp/mkpcheck ios/Idfon/Models.swift ios/Checks/MessageKindParseCheck/main.swift
//   /tmp/mkpcheck
//
// Prints "ALL OK" or the first failing assertion (exit 1).
import Foundation

func check(_ cond: Bool, _ msg: String) { if !cond { print("FAIL:", msg); exit(1) } else { print("ok:", msg) } }

// Models.swift's `Event` needs the type/conformance; the check never decodes one.
struct AnyEncodable: Decodable { let value: Any
    init(from decoder: Decoder) throws { value = NSNull() }
}

func isText(_ kind: MessageKind) -> Bool { if case .text = kind { return true } else { return false } }

check(isText(MessageKind.parse("hello")), "plain text passes through")
check(isText(MessageKind.parse("IDFON-FILE/1\nname=x\n")), "file envelope without a ticket falls back to text")
check(isText(MessageKind.parse("IDFON-RECORDING/1\n")), "recording envelope without a ticket falls back to text")

let fileEnvelope = """
IDFON-FILE/1
id=abc
name=Archive.zip
size=12345
sender_id=me
ticket=tkt-1
"""
if case .file(let ticket, let name, let sizeBytes, let localURL) = MessageKind.parse(fileEnvelope) {
    check(ticket == "tkt-1", "file ticket")
    check(name == "Archive.zip", "file name")
    check(sizeBytes == 12345, "file size")
    check(localURL == nil, "file localURL starts nil")
} else {
    check(false, "file envelope parses as .file")
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
if case .recording(let ticket, let durationMs, let localURL) = MessageKind.parse(recordingEnvelope) {
    check(ticket == "tkt-2", "recording ticket")
    check(durationMs == 2500, "recording duration")
    check(localURL == nil, "recording localURL starts nil")
} else {
    check(false, "recording envelope parses as .recording")
}

// Values split on the first `=`, so a name may contain one.
if case .file(_, let name, _, _) = MessageKind.parse("IDFON-FILE/1\nname=a=b.txt\nticket=t\n") {
    check(name == "a=b.txt", "value keeps later '=': \(name)")
} else {
    check(false, "name containing '=' parses")
}
print("ALL OK")
