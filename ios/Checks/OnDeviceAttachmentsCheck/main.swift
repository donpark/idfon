// Runnable check for `OnDeviceAttachments` (not part of the Xcode target).
// The helper is Foundation-only, so this compiles and runs on the host:
//
//   swiftc -o /tmp/odacheck ios/Idfon/OnDeviceAttachments.swift \
//     ios/Checks/OnDeviceAttachmentsCheck/main.swift
//   /tmp/odacheck
//
// Prints "ALL OK" or the first failing assertion (exit 1).
import Foundation

func check(_ cond: Bool, _ msg: String) { if !cond { print("FAIL:", msg); exit(1) } else { print("ok:", msg) } }

let dir = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("odacheck-\(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

func write(_ name: String, _ bytes: [UInt8]) -> URL {
    let url = dir.appendingPathComponent(name)
    try! Data(bytes).write(to: url)
    return url
}

// A text file is read whole.
let notes = write("notes.txt", Array("hello\nworld\n".utf8))
check(OnDeviceAttachments.text(at: notes) == "hello\nworld\n", "text file read")

// An empty file has nothing to attach.
let empty = write("empty.txt", [])
check(OnDeviceAttachments.text(at: empty) == nil, "empty file is refused")

// Binary content is refused instead of being sent as mojibake.
let binary = write("blob.bin", [0xFF, 0xFE, 0x00, 0x01, 0x80, 0xFF])
check(OnDeviceAttachments.text(at: binary) == nil, "binary file is refused")

// A missing file is refused, not crashed on.
check(OnDeviceAttachments.text(at: dir.appendingPathComponent("nope.txt")) == nil,
      "missing file is refused")

// The cap bounds the read, and a cut multi-byte character is dropped rather
// than making the whole file undecodable.
let big = write("big.log", Array(repeating: UInt8(ascii: "a"), count: 100) + Array("éé".utf8))
let capped = OnDeviceAttachments.text(at: big, maxBytes: 101)
check(capped?.utf8.count == 100, "cap bounds the read: \(capped?.utf8.count ?? -1)")
check(capped?.allSatisfy { $0 == "a" } == true, "the partial multi-byte tail is dropped")

// The turn input is the shape the loop's `TurnInput` decodes.
let input = OnDeviceAttachments.turnInput(text: "what is this?", name: "notes\n.txt", content: "body")
let attachments = input["attachments"] as? [[String: String]]
check(input["text"] as? String == "what is this?", "turn input carries the question")
check(attachments?.count == 1, "one attachment: \(String(describing: attachments?.count))")
check(attachments?.first?["kind"] == "text", "attachment kind is text")
check(attachments?.first?["name"] == "notes .txt", "the name cannot break the prompt label")
check(attachments?.first?["content"] == "body", "attachment carries the content")

try? FileManager.default.removeItem(at: dir)
print("ALL OK")
