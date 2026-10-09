//
//  LogComparator.swift
//  LogCatAndroid
//

import Foundation

/// The two devices being compared
enum CompareSide: String, Codable, Hashable {
    case left
    case right

    var other: CompareSide { self == .left ? .right : .left }
}

/// An event whose fields or values differ between the two devices, or that only one of them logged
struct CompareMismatch: Identifiable, Codable, Hashable {
    enum Kind: String, Codable, Hashable {
        /// Both devices logged the event, with different fields or values
        case fieldsDiffer
        /// Only one device logged the event during the comparison
        case missingOnOtherSide
    }

    /// A field whose value differs between the two devices
    struct ValueDifference: Codable, Hashable {
        let key: String
        let left: String
        let right: String
    }

    let id: UUID
    let kind: Kind
    let eventName: String
    /// Fields only the left (resp. right) device logged
    let onlyOnLeft: [String]
    let onlyOnRight: [String]
    let differentValues: [ValueDifference]
    /// The raw log lines, `nil` on the side that did not log the event
    let leftRawLine: String?
    let rightRawLine: String?
    let leftTimestamp: String?
    let rightTimestamp: String?
}

/// Pairs the analytics events of two devices and records those that do not match.
///
/// Events are paired by name, in the order they come in: the n-th `screen_view` of one device is
/// compared with the n-th `screen_view` of the other. Their parameters are flattened into dotted
/// paths so the Android (`params={…}`, `value={…}`) and iOS (`parameters=[{json}]`) payloads line up.
/// Values of id fields are not compared, since ids differ from one device to the other.
struct LogComparator {
    /// Root fields describing the log itself rather than the event (including the log's own `id`,
    /// as in PhotoPrint's `LogDomainModel(id=…)`): they naturally differ between platforms and app
    /// versions, so they are left out of the comparison
    static let envelopeKeys: Set<String> = [
        "id", "event", "logId", "eventVersion", "appVersion", "buildNumber", "threadMain", "timestamp",
    ]

    /// Containers holding the event's parameters: their children are compared as top-level fields,
    /// so `params.screen_name` (Android) and `parameters.screen_name` (iOS) both read `screen_name`
    static let parameterContainers: Set<String> = ["params", "parameters", "value"]

    /// Events seen on one side and not paired yet, per event name, oldest first
    private var pending: [CompareSide: [String: [LogEntry]]] = [.left: [:], .right: [:]]

    /// How many events were paired, matching or not
    private(set) var pairedCount = 0

    /// Feeds an event logged by `side`. Returns a mismatch when it pairs with an event of the
    /// other side that has different fields or values, `nil` otherwise.
    mutating func add(_ entry: LogEntry, from side: CompareSide) -> CompareMismatch? {
        let name = entry.eventName
        if var queue = pending[side.other]?[name], !queue.isEmpty {
            let partner = queue.removeFirst()
            pending[side.other]?[name] = queue
            pairedCount += 1
            let (left, right) = side == .left ? (entry, partner) : (partner, entry)
            return Self.compare(left: left, right: right)
        }
        pending[side, default: [:]][name, default: []].append(entry)
        return nil
    }

    /// Ends the comparison: every event still waiting for its partner is reported as missing on the other side
    mutating func finish() -> [CompareMismatch] {
        var mismatches: [CompareMismatch] = []
        for side in [CompareSide.left, .right] {
            let entries = (pending[side] ?? [:]).values.flatMap { $0 }.sorted { $0.index < $1.index }
            for entry in entries {
                mismatches.append(CompareMismatch(
                    id: UUID(),
                    kind: .missingOnOtherSide,
                    eventName: entry.eventName,
                    onlyOnLeft: [],
                    onlyOnRight: [],
                    differentValues: [],
                    leftRawLine: side == .left ? entry.rawLine : nil,
                    rightRawLine: side == .right ? entry.rawLine : nil,
                    leftTimestamp: side == .left ? entry.timestamp : nil,
                    rightTimestamp: side == .right ? entry.timestamp : nil
                ))
            }
        }
        pending = [.left: [:], .right: [:]]
        return mismatches
    }

    // MARK: - Field Comparison

    /// Compares two occurrences of the same event. `nil` when their fields and values match.
    static func compare(left: LogEntry, right: LogEntry) -> CompareMismatch? {
        let leftFields = comparableFields(of: left)
        let rightFields = comparableFields(of: right)
        let leftKeys = Set(leftFields.keys)
        let rightKeys = Set(rightFields.keys)

        let differentValues = leftKeys.intersection(rightKeys).sorted().compactMap { key -> CompareMismatch.ValueDifference? in
            guard !isIDKey(key), let leftValue = leftFields[key], let rightValue = rightFields[key],
                  leftValue != rightValue else { return nil }
            return CompareMismatch.ValueDifference(key: key, left: leftValue, right: rightValue)
        }
        let onlyOnLeft = leftKeys.subtracting(rightKeys).sorted()
        let onlyOnRight = rightKeys.subtracting(leftKeys).sorted()

        guard !differentValues.isEmpty || !onlyOnLeft.isEmpty || !onlyOnRight.isEmpty else { return nil }
        return CompareMismatch(
            id: UUID(),
            kind: .fieldsDiffer,
            eventName: left.eventName,
            onlyOnLeft: onlyOnLeft,
            onlyOnRight: onlyOnRight,
            differentValues: differentValues,
            leftRawLine: left.rawLine,
            rightRawLine: right.rawLine,
            leftTimestamp: left.timestamp,
            rightTimestamp: right.timestamp
        )
    }

    /// The event's fields as `path → value`, envelope fields left out and parameter containers flattened
    static func comparableFields(of entry: LogEntry) -> [String: String] {
        var fields: [String: String] = [:]
        flatten(entry.parsedFields, prefix: "", into: &fields)
        return fields
    }

    /// Adds `parsedFields` under `prefix` ("" at the root). List elements carry their `[n]` key,
    /// object children get a dot. Root parameter containers are transparent, so nested ones
    /// (PhotoPrint's `value={screen=…, parameters={…}}`) end up at the root too.
    private static func flatten(_ parsedFields: [LogEntry.ParsedField], prefix: String, into fields: inout [String: String]) {
        for field in parsedFields {
            let isRoot = prefix.isEmpty
            if isRoot, envelopeKeys.contains(field.key) { continue }

            let path: String
            if isRoot {
                path = field.key
            } else if field.key.hasPrefix("[") {
                path = prefix + field.key
            } else {
                path = prefix + "." + field.key
            }

            if field.isNested {
                let isParameterContainer = isRoot && parameterContainers.contains(field.key)
                flatten(field.children, prefix: isParameterContainer ? "" : path, into: &fields)
            } else {
                fields[path] = field.value
            }
        }
    }

    /// Whether the value of `key` is an identifier, which differs from one device to the other:
    /// `id`, `item_id`, `orderId`, `items[0].itemID`…
    static func isIDKey(_ key: String) -> Bool {
        let name = String(key.split(separator: ".").last ?? Substring(key))
            .replacingOccurrences(of: #"\[\d+\]$"#, with: "", options: .regularExpression)
        return name.lowercased() == "id" || name.hasSuffix("_id") || name.hasSuffix("Id") || name.hasSuffix("ID")
    }
}

// MARK: - Fix List

/// One line of a difference that can be added to the fix list, with a note describing the gap
struct MismatchFixCandidate: Identifiable, Hashable {
    enum Kind: Hashable {
        /// The field's value differs between the devices
        case differentValue
        /// Only one device logged the field
        case missingField
        /// Only one device logged the event
        case missingEvent
    }

    let kind: Kind
    /// The device whose log the fix item points at
    let side: CompareSide
    /// The compared field, or `event` when the whole event is missing on a device
    let fieldKey: String
    /// The field's value on `side`
    let fieldValue: String
    /// What differs, written for the fix list
    let note: String
    /// The line shown in the detail pane
    let label: String

    var id: String { "\(side.rawValue):\(fieldKey)" }
}

extension CompareMismatch {
    /// The difference split into fix list items: one per differing value, per field missing on a
    /// device, or one for the whole event when a device did not log it. Value differences point at
    /// the left device's log; fields logged by one device only point at that device's log.
    func fixCandidates(leftName: String, rightName: String) -> [MismatchFixCandidate] {
        switch kind {
        case .missingOnOtherSide:
            let side: CompareSide = leftRawLine != nil ? .left : .right
            let (logged, missing) = side == .left ? (leftName, rightName) : (rightName, leftName)
            return [MismatchFixCandidate(
                kind: .missingEvent, side: side, fieldKey: "event", fieldValue: eventName,
                note: "Logged by \(logged) but not by \(missing)",
                label: "Only logged by \(logged)"
            )]

        case .fieldsDiffer:
            var candidates = differentValues.map { difference in
                MismatchFixCandidate(
                    kind: .differentValue, side: .left, fieldKey: difference.key, fieldValue: difference.left,
                    note: "\(difference.key) differs: \(leftName) = \(difference.left), \(rightName) = \(difference.right)",
                    label: "\(difference.key): \(difference.left)  ≠  \(difference.right)"
                )
            }
            for (side, keys) in [(CompareSide.left, onlyOnLeft), (.right, onlyOnRight)] where !keys.isEmpty {
                let (logged, missing) = side == .left ? (leftName, rightName) : (rightName, leftName)
                let fields = entry(for: side).map(LogComparator.comparableFields(of:)) ?? [:]
                candidates += keys.map { key in
                    MismatchFixCandidate(
                        kind: .missingField, side: side, fieldKey: key, fieldValue: fields[key] ?? "",
                        note: "\(key) logged by \(logged) but missing on \(missing)",
                        label: "Only on \(logged): \(key)"
                    )
                }
            }
            return candidates
        }
    }

    /// The log `side` recorded, rebuilt from its raw line (several lines when tags were merged)
    func entry(for side: CompareSide) -> LogEntry? {
        guard let rawLine = side == .left ? leftRawLine : rightRawLine else { return nil }
        let lines = rawLine.split(separator: "\n").map(String.init)
        var entry = LogEntry.parse(line: lines.first ?? rawLine, index: 0)
        for line in lines.dropFirst() {
            entry.merge(LogEntry.parse(line: line, index: 0))
        }
        return entry
    }
}
