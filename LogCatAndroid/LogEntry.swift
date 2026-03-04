import Foundation

struct LogEntry: Identifiable, Equatable, Hashable {
    let id: UUID
    let timestamp: String
    let pid: String
    let tid: String
    let level: LogLevel
    let tag: String
    let message: String
    let rawLine: String
    let index: Int

    /// Parsed fields from the Kotlin data class toString() format
    let parsedFields: [ParsedField]

    /// The event name: uses the "event" field if available, otherwise the tag
    var eventName: String {
        if let eventField = parsedFields.first(where: { $0.key == "event" }) {
            return eventField.value
        }
        return tag.isEmpty ? "Unknown" : tag
    }

    struct ParsedField: Hashable, Identifiable {
        var id: String { key }
        let key: String
        let value: String
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
                    tag: components[4].trimmingCharacters(in: .whitespaces),
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
            tag: "",
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
            return []
        }

        let inner = String(input[input.index(after: openParen)..<closeParen])
        return splitTopLevelFields(inner)
    }

    /// Splits a comma-separated string respecting nested `{}`  and `()` pairs.
    private static func splitTopLevelFields(_ input: String) -> [ParsedField] {
        var fields: [ParsedField] = []
        var depth = 0
        var current = ""

        for char in input {
            switch char {
            case "{", "(":
                depth += 1
                current.append(char)
            case "}", ")":
                depth -= 1
                current.append(char)
            case "," where depth == 0:
                if let field = parseField(current.trimmingCharacters(in: .whitespaces)) {
                    fields.append(field)
                }
                current = ""
            default:
                current.append(char)
            }
        }

        // Last segment
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, let field = parseField(trimmed) {
            fields.append(field)
        }

        return fields
    }

    /// Parses a single `key=value` string into a ParsedField.
    private static func parseField(_ segment: String) -> ParsedField? {
        guard let eqIndex = segment.firstIndex(of: "=") else { return nil }
        let key = String(segment[segment.startIndex..<eqIndex]).trimmingCharacters(in: .whitespaces)
        let value = String(segment[segment.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return ParsedField(key: key, value: value)
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
