import XCTest

@testable import Idfon

/// Derivation rules of the §7.3 timeline engine: recency guard → burst
/// collapse → bucket cards, plus the drill-open contract (§7.4).
final class TimelineTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// Fixed "now": 2025-10-09 06:13 UTC — late enough in the day that
    /// hour-old messages are still "today".
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    private func message(_ id: String, minutesFromNow minutes: Double) -> ChatMessage {
        ChatMessage(id: id, peerId: "peer", kind: .text(id), outgoing: false,
                    timestamp: now.addingTimeInterval(minutes * 60))
    }

    /// Five messages within four minutes — a burst well past the guard.
    private func burst(_ prefix: String, at offset: Double) -> [ChatMessage] {
        (0..<5).map { message("\(prefix)\($0)", minutesFromNow: offset - Double($0)) }
    }

    func testBurstCollapsesToThread() {
        let items = Timeline.items(for: burst("a", at: -60), now: now, calendar: calendar)
        XCTAssertEqual(items.filter { if case .message = $0 { return true } else { return false } }.count, 0)
        let threads = items.compactMap { item -> [ChatMessage]? in
            if case .thread(_, let messages) = item { return messages }
            return nil
        }
        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads[0].count, 5)
    }

    func testUnderThresholdStaysInline() {
        let four = Array(burst("a", at: -60).dropLast())
        let items = Timeline.items(for: four, now: now, calendar: calendar)
        XCTAssertTrue(items.allSatisfy { if case .message = $0 { return true } else { return false } })
    }

    func testRecencyGuardKeepsTailInline() {
        // Same burst shape, but inside the last 10 minutes: never collapses.
        let items = Timeline.items(for: burst("a", at: -5), now: now, calendar: calendar)
        XCTAssertTrue(items.allSatisfy { if case .message = $0 { return true } else { return false } })
    }

    func testQuietStretchSplitsBursts() {
        // Two bursts 26 minutes apart must not merge into one thread.
        let items = Timeline.items(for: burst("a", at: -60) + burst("b", at: -30), now: now, calendar: calendar)
        let threads = items.compactMap { item -> Int? in
            if case .thread(_, let messages) = item { return messages.count }
            return nil
        }
        XCTAssertEqual(threads, [5, 5])
    }

    func testThreadDrillOpensInPlace() {
        let messages = burst("a", at: -60).sorted { $0.timestamp < $1.timestamp }
        let id = messages[0].id // a thread's id is its first message (§7.3b)
        let items = Timeline.items(for: messages, expanding: [id], now: now, calendar: calendar)
        // The thread card stays as the header; its messages follow.
        XCTAssertEqual(items.filter { if case .thread = $0 { return true } else { return false } }.count, 1)
        XCTAssertEqual(items.filter { if case .message = $0 { return true } else { return false } }.count, 5)
    }

    func testOlderMessagesBucketByDay() {
        let old = [message("o1", minutesFromNow: -3 * 24 * 60), message("o2", minutesFromNow: -3 * 24 * 60 - 30)]
        let items = Timeline.items(for: old, now: now, calendar: calendar)
        guard case .bucket(_, let label, let summary, let messages)? = items.first else {
            return XCTFail("expected a bucket, got \(items)")
        }
        XCTAssertFalse(label.isEmpty)
        XCTAssertEqual(summary, "2 messages")
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(items.count, 1, "a bucket is one row until drilled open")
    }

    func testBucketDrillOpensToItsMessages() {
        let old = [message("o1", minutesFromNow: -3 * 24 * 60), message("o2", minutesFromNow: -3 * 24 * 60 - 30)]
        let collapsed = Timeline.items(for: old, now: now, calendar: calendar)
        guard case .bucket(let id, _, _, _)? = collapsed.first else {
            return XCTFail("expected a bucket, got \(collapsed)")
        }
        let items = Timeline.items(for: old, expanding: [id], now: now, calendar: calendar)
        XCTAssertEqual(items.filter { if case .bucket = $0 { return true } else { return false } }.count, 1)
        XCTAssertEqual(items.filter { if case .message = $0 { return true } else { return false } }.count, 2)
    }

    func testTodayRegionCarriesDateline() {
        let items = Timeline.items(for: [message("t1", minutesFromNow: -60)], now: now, calendar: calendar)
        XCTAssertTrue(items.contains { if case .dateline(_, let text) = $0 { return text == "Today" } else { return false } })
    }

    func testSessionMarkerIsABoundary() {
        // D21: derived grouping never merges across the stored session_start
        // marker — these two bursts would otherwise share one 10-minute
        // window and collapse into a single thread.
        let marker = ChatMessage(id: "marker", peerId: "peer", kind: .sessionStart, outgoing: true,
                                 timestamp: now.addingTimeInterval(-55 * 60))
        let items = Timeline.items(for: burst("a", at: -60) + burst("b", at: -50) + [marker],
                                   now: now, calendar: calendar)
        let threads = items.compactMap { item -> Int? in
            if case .thread(_, let messages) = item { return messages.count }
            return nil
        }
        XCTAssertEqual(threads, [5, 5])
        XCTAssertTrue(items.contains {
            if case .dateline(_, let text) = $0 { return text == "New Session" } else { return false }
        })
    }

    func testRevisionChainsCollapseToLatest() {
        // §14: never a card per revision — the chain shows its latest only.
        func artifactMessage(_ id: String, revisionOf: String?, minutes: Double) -> ChatMessage {
            let metadata: JSONValue? = revisionOf.map { .object(["revision_of": .string($0)]) }
            let artifact = Artifact(artifactId: id, kind: .document, mime: "text/plain", title: id,
                                    sizeBytes: 1, blobTicket: nil, sourceMessageId: nil,
                                    conversation: nil, metadata: metadata, createdAt: "")
            return ChatMessage(id: "m-\(id)", peerId: "peer", kind: .artifact(artifact),
                               outgoing: false, timestamp: now.addingTimeInterval(minutes * 60))
        }
        let items = Timeline.items(for: [
            artifactMessage("a1", revisionOf: nil, minutes: -60),
            artifactMessage("a2", revisionOf: "a1", minutes: -59),
            artifactMessage("a3", revisionOf: "a2", minutes: -58),
        ], now: now, calendar: calendar)
        let rows = items.filter { if case .message = $0 { return true } else { return false } }
        XCTAssertEqual(rows.count, 1, "the chain collapses to its latest revision")
    }
}
