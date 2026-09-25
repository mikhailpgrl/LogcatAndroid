//
//  FixListStore.swift
//  LogCatAndroid
//

import Foundation

/// A log field flagged as needing a fix, together with the user's note about what to change
struct FixItem: Identifiable, Codable, Hashable {
    let id: UUID
    /// The live log entry this was taken from. Only resolvable within the session it was created in.
    let entryID: UUID
    let eventName: String
    /// Dotted path of the flagged field, e.g. `event` or `params.items[0].item_name`
    let fieldKey: String
    let fieldValue: String
    /// What needs to be modified
    let note: String
    let timestamp: String
    let rawLine: String
    let createdAt: Date

    init(entry: LogEntry, fieldKey: String, fieldValue: String, note: String) {
        id = UUID()
        entryID = entry.id
        eventName = entry.eventName
        self.fieldKey = fieldKey
        self.fieldValue = fieldValue
        self.note = note
        timestamp = entry.timestamp
        rawLine = entry.rawLine
        createdAt = Date()
    }

    /// Rebuilds the log entry from the stored raw line(s), for when the live entry
    /// is no longer in the buffer (app restarted or buffer trimmed)
    func reconstructedEntry() -> LogEntry {
        let lines = rawLine.split(separator: "\n").map(String.init)
        var entry = LogEntry.parse(line: lines.first ?? rawLine, index: 0)
        // Merged duplicates were stored one raw line per tag
        for line in lines.dropFirst() {
            entry.merge(LogEntry.parse(line: line, index: 0))
        }
        return entry
    }
}

/// The list of logs to fix, shown at the bottom of the sidebar and persisted across launches
final class FixListStore: ObservableObject {
    @Published private(set) var items: [FixItem] = [] {
        didSet { save() }
    }

    private static let storageKey = "fixList"

    init() {
        load()
    }

    func add(_ item: FixItem) {
        items.append(item)
    }

    func remove(_ item: FixItem) {
        items.removeAll { $0.id == item.id }
    }

    func removeAll() {
        items.removeAll()
    }

    // MARK: - Export

    /// The list formatted with Slack's mrkdwn syntax, grouped by event, ready to paste in a message
    func slackExport() -> String {
        Self.slackExport(of: items)
    }

    static func slackExport(of items: [FixItem]) -> String {
        guard !items.isEmpty else { return "" }

        var lines: [String] = []
        lines.append("*Analytics logs to fix* (\(items.count))")
        lines.append("")

        // Group by event, keeping the order in which events were first flagged
        var eventOrder: [String] = []
        var itemsByEvent: [String: [FixItem]] = [:]
        for item in items {
            if itemsByEvent[item.eventName] == nil {
                eventOrder.append(item.eventName)
            }
            itemsByEvent[item.eventName, default: []].append(item)
        }

        for eventName in eventOrder {
            lines.append("• *\(eventName)*")
            for item in itemsByEvent[eventName] ?? [] {
                var line = "    ◦ `\(item.fieldKey)` = `\(slackSafe(item.fieldValue))`"
                if !item.note.isEmpty {
                    line += " → _\(item.note)_"
                }
                lines.append(line)
            }
        }

        return lines.joined(separator: "\n")
    }

    /// Keeps a value on one line and prevents it from closing the surrounding inline code span
    private static func slackSafe(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "`", with: "'")
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([FixItem].self, from: data) else { return }
        items = decoded
    }
}
