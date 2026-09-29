#!/usr/bin/env bash
# Self-check for the idfon:// link parser (Track A addressing).
#
# The parser is duplicated between ios/Idfon and mac/Sources/Idfon (the apps
# have no shared Swift module). This compiles each copy with the same assert
# main, so the two copies cannot silently drift.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/main.swift" <<'SWIFT'
import Foundation

func expect(_ url: String, _ want: IdfonURL, _ note: String) {
    guard let got = IdfonURL(URL(string: url)!) else { fatalError("\(note): did not parse \(url)") }
    precondition(got == want, "\(note): \(url) -> \(got), want \(want)")
}

func expectNil(_ url: String, _ note: String) {
    precondition(IdfonURL(URL(string: url)!) == nil, "\(note): \(url) should not parse")
}

// An endpoint-id host is a resource; the path is retained.
expect("idfon://6b4e1234567890abcdef/y/z",
       .resource(ref: "6b4e1234567890abcdef", path: ["y", "z"]), "endpoint id")
// Hex endpoint ids normalize to lowercase (iroh's canonical rendering).
expect("idfon://" + String(repeating: "A", count: 64),
       .resource(ref: String(repeating: "a", count: 64), path: []), "uppercase hex id")
// Alias/name hosts keep their case and become a resource ref.
expect("idfon://Alice/chat", .resource(ref: "Alice", path: ["chat"]), "alias")
// Reserved verbs win; the ref is the first path segment.
expect("idfon://dial/Bob", .dial(ref: "Bob"), "dial")
expect("idfon://videodial/Bob", .videoDial(ref: "Bob"), "videodial")
expect("idfon://answer", .answer, "answer")
// No host: the verb lives in the path.
expect("idfon:///dial/Carol", .dial(ref: "Carol"), "no-host verb")
// Scheme is required and case-insensitive.
expect("IDFON://Bob", .resource(ref: "Bob", path: []), "scheme case")
expectNil("https://example.com/x", "wrong scheme")
// A verb with no ref is not a link.
expectNil("idfon://dial", "dial without ref")
print("idfon-url: ok")
SWIFT

for src in "$root/ios/Idfon/IdfonURL.swift" "$root/mac/Sources/Idfon/IdfonURL.swift"; do
    swiftc -o "$tmp/check" "$src" "$tmp/main.swift"
    "$tmp/check"
done
