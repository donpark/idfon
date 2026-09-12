// Runnable check for `MessageKind.parse` (not part of the app target).
// Models.swift is Foundation-only, so this runs on the host with plain swiftc:
//
//   swiftc -o /tmp/mkpcheck mac/Sources/Idfon/Models.swift \
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

print("ALL OK")
