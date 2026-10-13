import Foundation

/// §7.3 timeline derivation: a room's messages → display items.
///
/// Presentation only (P3/D17): messages never move, only their grouping is
/// derived, and it is re-derived on every update — retroactive regrouping
/// (D17) falls out of that for free. Precedence (§7.3): recency guard → burst
/// collapse → bucket cards.
///
/// shortcut: no `session_start` boundary (D21) — the marker event is not in
/// the message model yet; when it lands, split burst runs on it here.
enum Timeline {
    // §7.3a tuning knobs — the one place to retune (no config UI, P11).
    // Conservative defaults: under-collapse beats over-collapse.
    /// Burst ≈ `burstCount` messages within `burstWindow` → thread item.
    static let burstCount = 5
    static let burstWindow: TimeInterval = 10 * 60
    /// Recency guard: the last `recencyWindow` never collapses. The one rule
    /// that prevents the worst failure — content hiding under the reader.
    static let recencyWindow: TimeInterval = 10 * 60
    /// Bucket ages (days back): today expands inline; up to a week collapses
    /// to day cards, then week / month / year cards. "Buckets only bite well
    /// in the past."
    static let dayCardMaxDays = 7
    static let weekCardMaxDays = 30
    static let monthCardMaxDays = 365

    /// One row of the derived timeline. Ids are stable across re-derivations
    /// (§7.3b): a thread is its first message, a bucket its range.
    enum Item {
        case message(ChatMessage)
        case dateline(id: String, text: String)
        case thread(id: String, messages: [ChatMessage])
        case bucket(id: String, label: String, summary: String, messages: [ChatMessage])

        var id: String {
            switch self {
            case .message(let message): return message.id
            case .dateline(let id, _): return id
            case .thread(let id, _): return id
            case .bucket(let id, _, _, _): return id
            }
        }
    }

    /// Derive display items for `messages` (any order). A card whose id is in
    /// `expanding` is drilled open in place (§7.4): it stays as the header and
    /// its messages follow.
    static func items(
        for messages: [ChatMessage],
        expanding: Set<String> = [],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [Item] {
        let sorted = messages.sorted { $0.timestamp < $1.timestamp }
        // D21: `session_start` markers are the one stored grouping boundary —
        // derived grouping never merges across them. Each marker renders as a
        // divider and the segments on either side derive independently.
        var items: [Item] = []
        var segment: [ChatMessage] = []
        for message in sorted {
            if case .sessionStart = message.kind {
                items += derived(segment, expanding: expanding, now: now, calendar: calendar)
                items.append(.dateline(id: message.id, text: "New Session"))
                segment = []
            } else {
                segment.append(message)
            }
        }
        return items + derived(segment, expanding: expanding, now: now, calendar: calendar)
    }

    private static func derived(
        _ messages: [ChatMessage],
        expanding: Set<String>,
        now: Date,
        calendar: Calendar
    ) -> [Item] {
        let todayStart = calendar.startOfDay(for: now)
        return buckets(messages.filter { $0.timestamp < todayStart }, expanding: expanding, now: now, calendar: calendar)
            + inline(messages.filter { $0.timestamp >= todayStart }, expanding: expanding, now: now,
                     calendar: calendar, collapse: true)
    }

    // MARK: - Inline region (today, and the inside of drilled-open cards)

    /// Messages as inline rows with datelines and (today only) burst collapse.
    private static func inline(
        _ messages: [ChatMessage],
        expanding: Set<String>,
        now: Date,
        calendar: Calendar,
        collapse: Bool
    ) -> [Item] {
        let bursty = collapse ? burstMask(messages, now: now) : Set<String>()
        var items: [Item] = []
        var run: [ChatMessage] = [] // pending burst run
        var lastDay: DateComponents?

        /// A long enough run becomes a thread card (or a card plus its messages
        /// when drilled open); anything shorter stays inline.
        func flushRun() {
            defer { run = [] }
            guard run.count >= burstCount else {
                items.append(contentsOf: run.map { .message($0) })
                return
            }
            let id = run[0].id
            items.append(.thread(id: id, messages: run))
            if expanding.contains(id) { items.append(contentsOf: run.map { .message($0) }) }
        }

        for message in messages {
            let day = calendar.dateComponents([.year, .month, .day], from: message.timestamp)
            if day != lastDay {
                flushRun()
                items.append(.dateline(id: "dateline-\(day.year ?? 0)-\(day.month ?? 0)-\(day.day ?? 0)",
                                       text: datelineText(day, now: now, calendar: calendar)))
                lastDay = day
            }
            // A burst run continues only while members stay inside one burst
            // window of each other; a quiet stretch starts a new run.
            let inRun = bursty.contains(message.id)
                && (run.isEmpty
                    || message.timestamp.timeIntervalSince(run[run.count - 1].timestamp) <= burstWindow)
            if !inRun {
                flushRun()
                if !bursty.contains(message.id) {
                    items.append(.message(message))
                    continue
                }
            }
            run.append(message)
        }
        flushRun()
        return items
    }

    /// Bursty = some `burstWindow` window holds ≥ `burstCount` messages (§7.3).
    /// The recency guard keeps the "currently reading" tail out of it.
    private static func burstMask(_ messages: [ChatMessage], now: Date) -> Set<String> {
        let cutoff = now.addingTimeInterval(-recencyWindow)
        var ids = Set<String>()
        var end = 0
        for start in messages.indices {
            while end < messages.count,
                  messages[end].timestamp.timeIntervalSince(messages[start].timestamp) <= burstWindow {
                end += 1
            }
            if end - start >= burstCount {
                for k in start..<end where messages[k].timestamp < cutoff { ids.insert(messages[k].id) }
            }
        }
        return ids
    }

    // MARK: - Buckets (older than today)

    /// Contiguous same-range runs → one bucket card each (§7.3). A drilled-open
    /// card (§7.4) keeps its header and opens to its inline messages.
    private static func buckets(
        _ messages: [ChatMessage],
        expanding: Set<String>,
        now: Date,
        calendar: Calendar
    ) -> [Item] {
        var items: [Item] = []
        var run: [ChatMessage] = []
        var runKey = ""

        func flushRun() {
            defer { run = [] }
            guard !run.isEmpty else { return }
            let id = "bucket-\(runKey)"
            items.append(.bucket(id: id, label: bucketLabel(run[0].timestamp, now: now, calendar: calendar),
                                 summary: summary(run), messages: run))
            if expanding.contains(id) {
                items += inline(run, expanding: expanding, now: now, calendar: calendar, collapse: false)
            }
        }

        for message in messages {
            let key = bucketKey(message.timestamp, now: now, calendar: calendar)
            if key != runKey {
                flushRun()
                runKey = key
            }
            run.append(message)
        }
        flushRun()
        return items
    }

    /// The bucket a message belongs to: granularity + range start, one string
    /// key so runs merge per range (keys are monotone in time, so equal keys
    /// are always adjacent).
    private static func bucketKey(_ timestamp: Date, now: Date, calendar: Calendar) -> String {
        let (component, start) = bucketRange(timestamp, now: now, calendar: calendar)
        return "\(String(describing: component))-\(Int(start.timeIntervalSince1970))"
    }

    private static func bucketRange(_ timestamp: Date, now: Date, calendar: Calendar)
        -> (component: Calendar.Component, start: Date) {
        let daysBack = calendar.dateComponents([.day], from: calendar.startOfDay(for: timestamp),
                                               to: calendar.startOfDay(for: now)).day ?? 0
        let component: Calendar.Component
        if daysBack <= dayCardMaxDays {
            component = .day
        } else if daysBack <= weekCardMaxDays {
            component = .weekOfMonth
        } else if daysBack <= monthCardMaxDays {
            component = .month
        } else {
            component = .year
        }
        let start = calendar.dateInterval(of: component, for: timestamp)?.start ?? timestamp
        return (component, start)
    }

    /// The card's date-range label: "Tue, Mar 4", "Mar 3 – Mar 9", "Feb 2026", "2025".
    private static func bucketLabel(_ timestamp: Date, now: Date, calendar: Calendar) -> String {
        let (component, start) = bucketRange(timestamp, now: now, calendar: calendar)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        switch component {
        case .day:
            formatter.dateFormat = "EEE, MMM d"
            return formatter.string(from: timestamp)
        case .weekOfMonth:
            formatter.dateFormat = "MMM d"
            let end = calendar.date(byAdding: .day, value: -1,
                                    to: calendar.dateInterval(of: .weekOfMonth, for: timestamp)?.end ?? timestamp)
                ?? timestamp
            return "\(formatter.string(from: start)) – \(formatter.string(from: end))"
        case .month:
            formatter.dateFormat = "MMM yyyy"
            return formatter.string(from: timestamp)
        default:
            formatter.dateFormat = "yyyy"
            return formatter.string(from: timestamp)
        }
    }

    /// Bucket summary (A2): counts enough to know "when we talked about X".
    private static func summary(_ messages: [ChatMessage]) -> String {
        var calls = Set<String>()
        var files = 0
        for message in messages {
            switch message.kind {
            case .callTranscript(let transcript): calls.insert(transcript.callId)
            case .file, .recording: files += 1
            default: break
            }
        }
        var parts = ["\(messages.count) message\(messages.count == 1 ? "" : "s")"]
        if !calls.isEmpty { parts.append("\(calls.count) call\(calls.count == 1 ? "" : "s")") }
        if files > 0 { parts.append("\(files) file\(files == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    /// Dateline text: "Today", "Yesterday", "Tue, Mar 4", "Mar 4, 2025".
    private static func datelineText(_ day: DateComponents, now: Date, calendar: Calendar) -> String {
        guard let date = calendar.date(from: day) else { return "" }
        let daysBack = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                               to: calendar.startOfDay(for: now)).day ?? 0
        if daysBack == 0 { return "Today" }
        if daysBack == 1 { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.dateFormat = daysBack > 365 ? "MMM d, yyyy" : "EEE, MMM d"
        return formatter.string(from: date)
    }
}
