import Foundation

struct LogEntry: Identifiable, Equatable, Hashable {
    let id: UUID
    let timestamp: String
    let pid: String
    let tid: String
    let level: LogLevel
    /// The logger tags this event was emitted under. Several when the same event
    /// was logged through multiple loggers (e.g. `Analytics` and `AnalyticsPostHog`).
    private(set) var tags: [String]
    let message: String
    /// The raw logcat line(s), one per merged tag
    private(set) var rawLine: String
    let index: Int

    /// Parsed fields from the Kotlin data class toString() format
    let parsedFields: [ParsedField]

    /// The primary tag (the first one this event was seen with)
    var tag: String { tags.first ?? "" }

    /// The event name: uses the "event" field if available, otherwise the tag
    var eventName: String {
        if let eventField = parsedFields.first(where: { $0.key == "event" }) {
            return eventField.value
        }
        return tag.isEmpty ? "Unknown" : tag
    }

    /// The `id` field of the payload, when the app logs one (PhotoPrint's `LogDomainModel(id=...)`)
    var payloadId: String? {
        parsedFields.first(where: { $0.key == "id" })?.value
    }

    /// Whether `other` is the same event as this one, emitted through a logger tag
    /// not yet seen on this entry. Same content, same process and same payload id are required.
    func isSameEvent(as other: LogEntry) -> Bool {
        message == other.message
            && pid == other.pid
            && payloadId == other.payloadId
            && !other.tags.contains(where: tags.contains)
    }

    /// Absorbs `other` (a duplicate under another tag) into this entry
    mutating func merge(_ other: LogEntry) {
        tags.append(contentsOf: other.tags.filter { !tags.contains($0) })
        rawLine += "\n" + other.rawLine
    }

    struct ParsedField: Hashable, Identifiable {
        /// The shape of the value: a plain scalar, a `{key=value}` object, or a `[a, b]` list
        enum Kind: Hashable {
            case leaf
            case object
            case list
        }

        let key: String
        let value: String
        let kind: Kind
        let children: [ParsedField]

        var id: String { key }

        /// Whether this field has nested sub-fields
        var isNested: Bool { !children.isEmpty }

        /// Short description of a container's contents, shown while it is collapsed
        var summary: String {
            switch kind {
            case .leaf: return ""
            case .object: return children.count == 1 ? "1 field" : "\(children.count) fields"
            case .list: return children.count == 1 ? "1 item" : "\(children.count) items"
            }
        }

        init(key: String, value: String, kind: Kind = .leaf, children: [ParsedField] = []) {
            self.key = key
            self.value = value
            self.kind = kind
            self.children = children
        }
    }

    enum LogLevel: String, CaseIterable {
        case verbose = "V"
        case debug = "D"
        case info = "I"
        case warning = "W"
        case error = "E"
        case fatal = "F"
        case silent = "S"
        case unknown = "?"

        var displayName: String {
            switch self {
            case .verbose: return "Verbose"
            case .debug: return "Debug"
            case .info: return "Info"
            case .warning: return "Warning"
            case .error: return "Error"
            case .fatal: return "Fatal"
            case .silent: return "Silent"
            case .unknown: return "Unknown"
            }
        }

        var symbol: String {
            switch self {
            case .verbose: return "text.alignleft"
            case .debug: return "ladybug"
            case .info: return "info.circle"
            case .warning: return "exclamationmark.triangle"
            case .error: return "xmark.octagon"
            case .fatal: return "flame"
            case .silent: return "speaker.slash"
            case .unknown: return "questionmark.circle"
            }
        }
    }

    /// Extracts the PID from a standard logcat line
    /// (`MM-DD HH:MM:SS.mmm  PID  TID LEVEL TAG: MESSAGE`) without running the full parser.
    static func extractPid(from line: String) -> String? {
        let columns = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard columns.count >= 3 else { return nil }
        let pid = String(columns[2])
        return Int(pid) != nil ? pid : nil
    }

    /// Extracts the message part (everything after `TAG: `) from a standard logcat line
    /// without running the full parser. Returns `nil` when the line is not in the standard format.
    static func extractMessage(from line: String) -> String? {
        // Columns: date, time, PID, TID, level, then "TAG: MESSAGE"
        let columns = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
        guard columns.count == 6, Int(columns[2]) != nil else { return nil }
        let tagAndMessage = columns[5]
        guard let separator = tagAndMessage.range(of: ": ") else { return nil }
        return String(tagAndMessage[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
    }

    /// Parse a logcat line in the standard format:
    /// `MM-DD HH:MM:SS.mmm  PID  TID LEVEL TAG: MESSAGE`
    static func parse(line: String, index: Int) -> LogEntry {
        let pattern = #"^(\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\.\d+)\s+(\d+)\s+(\d+)\s+([VDIWEFS])\s+(.+?):\s+(.*)"#

        if let match = line.range(of: pattern, options: .regularExpression) {
            let matched = String(line[match])
            let components = matched.captureGroups(pattern: pattern)

            if components.count == 6 {
                let level = LogLevel(rawValue: components[3]) ?? .unknown
                let msg = components[5]
                let fields = parseKotlinDataClass(msg)
                return LogEntry(
                    id: UUID(),
                    timestamp: components[0],
                    pid: components[1],
                    tid: components[2],
                    level: level,
                    tags: [components[4].trimmingCharacters(in: .whitespaces)],
                    message: msg,
                    rawLine: line,
                    index: index,
                    parsedFields: fields
                )
            }
        }

        let fields = parseKotlinDataClass(line)
        return LogEntry(
            id: UUID(),
            timestamp: "",
            pid: "",
            tid: "",
            level: .unknown,
            tags: [],
            message: line,
            rawLine: line,
            index: index,
            parsedFields: fields
        )
    }

    /// Parses a Kotlin data class toString() format like:
    /// `LogDomainModel(id=abc, event=foo, value={screen=X, parameters={a=B}}, appVersion=1)`
    /// into an array of key-value pairs, correctly handling nested braces.
    static func parseKotlinDataClass(_ input: String) -> [ParsedField] {
        // Find the content inside the outermost parentheses
        guard let openParen = input.firstIndex(of: "("),
              let closeParen = input.lastIndex(of: ")") else {
            // Bare messages without a wrapping data class, e.g. Pictadroid's
            // `event=screen_view params={screen_name=home, screen_class=home}`
            // where top-level fields are separated by spaces.
            if input.hasPrefix("event=") {
                return splitTopLevelFields(input, splitOnWhitespace: true)
            }
            return []
        }

        let inner = String(input[input.index(after: openParen)..<closeParen])
        return splitTopLevelFields(inner)
    }

    /// Splits a comma-separated string of `key=value` pairs into fields,
    /// respecting nested `{}`, `[]` and `()` pairs.
    /// With `splitOnWhitespace`, top-level fields may also be separated by spaces.
    private static func splitTopLevelFields(_ input: String, splitOnWhitespace: Bool = false) -> [ParsedField] {
        splitTopLevelSegments(input, splitOnWhitespace: splitOnWhitespace).compactMap(parseField)
    }

    /// Splits `input` on top-level commas (and optionally spaces), keeping anything inside
    /// `{}`, `[]` or `()` together. Quoted strings are kept intact too so JSON payloads survive.
    private static func splitTopLevelSegments(_ input: String, splitOnWhitespace: Bool = false) -> [String] {
        var segments: [String] = []
        var depth = 0
        var inQuotes = false
        var current = ""

        for char in input {
            // Inside a quoted string nothing is structural except the closing quote
            if inQuotes {
                if char == "\"" { inQuotes = false }
                current.append(char)
                continue
            }

            switch char {
            case "\"":
                inQuotes = true
                current.append(char)
            case "{", "(", "[":
                depth += 1
                current.append(char)
            case "}", ")", "]":
                depth -= 1
                current.append(char)
            case "," where depth == 0,
                 " " where depth == 0 && splitOnWhitespace:
                segments.append(current)
                current = ""
            default:
                current.append(char)
            }
        }
        segments.append(current)

        return segments
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Parses a single `key=value` (or JSON-style `"key": value`) string into a ParsedField.
    /// Object and list values are recursively parsed into children.
    private static func parseField(_ segment: String) -> ParsedField? {
        // Kotlin uses `=`; JSON uses `:`. Take whichever separator comes first.
        guard let separator = segment.firstIndex(where: { $0 == "=" || $0 == ":" }) else { return nil }
        let key = unquoted(String(segment[segment.startIndex..<separator]))
        let value = String(segment[segment.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }

        return makeField(key: key, value: value)
    }

    /// Builds a field for `value`, expanding `{...}` objects and `[...]` lists into children
    private static func makeField(key: String, value: String) -> ParsedField {
        if value.hasPrefix("{") && value.hasSuffix("}") {
            let inner = String(value.dropFirst().dropLast())
            let children = splitTopLevelFields(inner)
            if !children.isEmpty {
                return ParsedField(key: key, value: value, kind: .object, children: children)
            }
        }

        if value.hasPrefix("[") && value.hasSuffix("]") {
            let inner = String(value.dropFirst().dropLast())
            // List elements have no key of their own: index them as [0], [1], ...
            let children = splitTopLevelSegments(inner).enumerated().map { index, element in
                makeField(key: "[\(index)]", value: element)
            }
            if !children.isEmpty {
                return ParsedField(key: key, value: value, kind: .list, children: children)
            }
        }

        return ParsedField(key: key, value: unquoted(value))
    }

    /// Trims whitespace and removes a surrounding pair of double quotes, if any
    private static func unquoted(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") else { return trimmed }
        return String(trimmed.dropFirst().dropLast())
    }
}

// MARK: - String Regex Helper
extension String {
    func captureGroups(pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(startIndex..., in: self)
        guard let match = regex.firstMatch(in: self, range: range) else { return [] }

        return (1..<match.numberOfRanges).compactMap { i in
            let r = match.range(at: i)
            guard r.location != NSNotFound, let swiftRange = Range(r, in: self) else { return nil }
            return String(self[swiftRange])
        }
    }
}
