// Runnable check for the menu contact's OPML parsing (not part of the app
// target). MenuDocument is Foundation-only, so this compiles and runs on the
// host:
//
//   swiftc -o /tmp/mac-menucheck mac/Sources/Idfon/MenuDocument.swift \
//     mac/Checks/MenuDocumentCheck/main.swift
//   /tmp/mac-menucheck
//
// Prints "ALL OK" or the first failing assertion (exit 1).
import Foundation

func check(_ cond: Bool, _ msg: String) { if !cond { print("FAIL:", msg); exit(1) } else { print("ok:", msg) } }

let fixture = """
<?xml version="1.0" encoding="UTF-8"?>
<opml version="2.0">
  <head><title>Talk radio &amp; friends</title></head>
  <body>
    <outline text="News">
      <outline text="Morning Briefing" type="audio" url="https://example.com/morning.m3u8" />
      <outline title="Evening Report" url="cache/evening.wav"></outline>
    </outline>
    <outline text="Tech" xmlUrl="https://example.com/tech.m3u8" />
  </body>
</opml>
"""

let document = MenuDocument.parse(Data(fixture.utf8))
check(document != nil, "fixture parses")
let entries = document?.entries ?? []
check(entries.count == 2, "two top-level entries")
check(entries.first?.title == "News", "section titled from text")
check(entries.first?.children.count == 2, "section has two children")
check(entries.first?.children.first?.title == "Morning Briefing", "child titled from text")
check(entries.first?.children.first?.source == "https://example.com/morning.m3u8", "url is the source")
check(entries.first?.children.last?.title == "Evening Report", "title attribute labels when text is absent")
check(entries.first?.children.last?.source == "cache/evening.wav", "bare path is still a source")
check(entries.last?.source == "https://example.com/tech.m3u8", "xmlUrl is the source when url is absent")
check(entries.first?.isPlayable == false, "a section is not playable")
check(entries.last?.isPlayable == true, "a show is playable")

// Segments: titles ride as-is; a title with the path separator falls back to
// its 1-based index.
check(MenuDocument.segment(MenuEntry(title: "Morning Briefing", source: nil, children: []), at: 0) == "Morning Briefing", "plain title is the segment")
check(MenuDocument.segment(MenuEntry(title: "AM/FM", source: nil, children: []), at: 2) == "3", "slash title falls back to the index")

// Malformed XML does not parse.
check(MenuDocument.parse(Data("<opml><body><outline text=\"x\">".utf8)) == nil, "malformed XML fails")

print("ALL OK")
