//
//  CompareIgnoreRules.swift
//  LogCatAndroid
//

import Foundation

/// A difference the device comparison should not report, for one event or for every event
struct CompareIgnoreRule: Identifiable, Codable, Hashable {
    enum Kind: String, Codable, Hashable {
        /// The field's value may differ; the field must still be logged by both devices
        case value
        /// The field is not compared at all: neither its value nor whether a device logged it
        case field
        /// The event is not compared at all, e.g. one only one platform logs
        case event
    }

    let id: UUID
    let kind: Kind
    /// The flattened field path (`screen_class`, `items[0].quantity`), or the event name for `.event`
    let key: String
    /// The event the rule is limited to, `nil` for every event. Unused for `.event`.
    let eventName: String?

    init(kind: Kind, key: String, eventName: String? = nil) {
        id = UUID()
        self.kind = kind
        self.key = key
        self.eventName = kind == .event ? nil : eventName
    }

    /// The rule as listed in the ignored panel, e.g. "Value of screen_class"
    var title: String {
        switch kind {
        case .value: return "Value of \(key)"
        case .field: return "Field \(key)"
        case .event: return "Event \(key)"
        }
    }

    /// Where the rule applies, e.g. "in screen_view" or "in all events"
    var scope: String {
        switch kind {
        case .event: return "never compared"
        case .value, .field: return eventName.map { "in \($0)" } ?? "in all events"
        }
    }

    /// Whether two rules ignore the same thing, whatever their id
    func isSameRule(as other: CompareIgnoreRule) -> Bool {
        kind == other.kind && key == other.key && eventName == other.eventName
    }

    fileprivate func applies(toField key: String, in event: String) -> Bool {
        self.key == key && (eventName == nil || eventName == event)
    }
}

extension CompareMismatch {
    /// The difference without what `rules` ignore, `nil` when nothing is left to report.
    /// Keeps the id, so a selected difference stays selected while rules change.
    func applying(_ rules: [CompareIgnoreRule]) -> CompareMismatch? {
        guard !rules.isEmpty else { return self }
        if rules.contains(where: { $0.kind == .event && $0.key == eventName }) { return nil }
        guard kind == .fieldsDiffer else { return self }

        func ignoresField(_ key: String) -> Bool {
            rules.contains { $0.kind == .field && $0.applies(toField: key, in: eventName) }
        }
        func ignoresValue(_ key: String) -> Bool {
            rules.contains { ($0.kind == .field || $0.kind == .value) && $0.applies(toField: key, in: eventName) }
        }

        let differentValues = differentValues.filter { !ignoresValue($0.key) }
        let onlyOnLeft = onlyOnLeft.filter { !ignoresField($0) }
        let onlyOnRight = onlyOnRight.filter { !ignoresField($0) }
        guard !differentValues.isEmpty || !onlyOnLeft.isEmpty || !onlyOnRight.isEmpty else { return nil }

        return CompareMismatch(
            id: id,
            kind: kind,
            eventName: eventName,
            onlyOnLeft: onlyOnLeft,
            onlyOnRight: onlyOnRight,
            differentValues: differentValues,
            leftRawLine: leftRawLine,
            rightRawLine: rightRawLine,
            leftTimestamp: leftTimestamp,
            rightTimestamp: rightTimestamp
        )
    }
}

/// The ignore rules of the device comparison, persisted across launches and shared by every
/// compare window
final class CompareIgnoreStore: ObservableObject {
    static let shared = CompareIgnoreStore()

    /// Oldest first
    @Published private(set) var rules: [CompareIgnoreRule] = [] {
        didSet { save() }
    }

    private static let storageKey = "compareIgnoreRules"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([CompareIgnoreRule].self, from: data) {
            rules = decoded
        }
    }

    /// Adds `rule` unless the same one is already there
    func add(_ rule: CompareIgnoreRule) {
        guard !rules.contains(where: { $0.isSameRule(as: rule) }) else { return }
        rules.append(rule)
    }

    func remove(_ rule: CompareIgnoreRule) {
        rules.removeAll { $0.id == rule.id }
    }

    func removeAll() {
        rules.removeAll()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
