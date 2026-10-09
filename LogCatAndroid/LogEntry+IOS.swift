//
//  LogEntry+IOS.swift
//  LogCatAndroid
//

import Foundation

/// Parsing of the iOS syslog lines relayed by `idevicesyslog` and of the Pictalytics payloads they carry.
/// The Android logcat format is parsed in `LogEntry.swift`.
extension LogEntry {
    /// Extracts the process name from an iOS syslog line
    /// (`Mon DD HH:MM:SS.ffffff Process(Image)[PID] <Level>: MESSAGE`) without running the full parser
    static func extractIOSProcess(from line: String) -> String? {
        // Columns: month, day, time, then "Process(Image)[PID] <Level>: MESSAGE"
        let columns = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard columns.count == 4,
              let end = columns[3].firstIndex(where: { $0 == "(" || $0 == "[" }) else { return nil }
        let process = columns[3][..<end]
        return process.isEmpty ? nil : String(process)
    }

    /// Parse an iOS syslog line as relayed by `idevicesyslog`:
    /// `Mon DD HH:MM:SS.ffffff Process(Image)[PID] <Level>: MESSAGE`.
    /// The image (the binary that logged) is only printed when it differs from the process.
    static func parseIOS(line: String, index: Int) -> LogEntry? {
        let pattern = #"^([A-Z][a-z]{2}\s+\d{1,2} \d{2}:\d{2}:\d{2}(?:\.\d+)?) (.+?)(?:\(([^)]*)\))?\[(\d+)\] <(\w+)>: (.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line))
        else { return nil }

        // An optional group that did not participate in the match reads as an empty string
        func group(_ number: Int) -> String {
            let range = match.range(at: number)
            guard range.location != NSNotFound, let swiftRange = Range(range, in: line) else { return "" }
            return String(line[swiftRange])
        }

        let (process, image, message) = (group(2), group(3), group(6))
        // The subsystem and category are not relayed: the image that logged is the closest thing
        // to a tag. The app's own code (no image, or `Picta.debug.dylib` in Debug builds) uses the process.
        let tag = image.isEmpty || image.hasPrefix(process) ? process : image
        return LogEntry(
            id: UUID(),
            timestamp: compactIOSTimestamp(group(1)),
            pid: group(4),
            tid: "",
            level: LogLevel.fromIOS(group(5)),
            tags: [tag],
            message: message,
            rawLine: line,
            index: index,
            parsedFields: parseBracketedFields(message)
        )
    }

    /// Rewrites an iOS timestamp (`Oct  8 15:10:12.995114`) in the shape of logcat's (`10-08 15:10:12.995`)
    /// so rows line up whatever the platform. Returns `timestamp` unchanged when it cannot be read.
    private static func compactIOSTimestamp(_ timestamp: String) -> String {
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let parts = timestamp.split(separator: " ")
        guard parts.count == 3,
              let month = months.firstIndex(of: String(parts[0])),
              let day = Int(parts[1]) else { return timestamp }

        // Milliseconds, like logcat
        var time = parts[2]
        if let dot = time.firstIndex(of: "."), time.distance(from: dot, to: time.endIndex) > 4 {
            time = time[..<time.index(dot, offsetBy: 4)]
        }
        return String(format: "%02d-%02d ", month + 1, day) + time
    }

    // MARK: - Pictalytics payloads

    /// Parses the `key=[value]` pairs the iOS apps log, e.g.
    /// `📝: register - logId=[select_content] parameters=[{"content_name":"back"}] eventVersion=[5.7.0] threadMain=[false]`.
    /// A value runs until the next ` key=[`, not the first `]`, since the JSON parameters may hold arrays.
    static func parseBracketedFields(_ input: String) -> [ParsedField] {
        guard let regex = try? NSRegularExpression(pattern: #"(?:^|\s)(\w+)=\["#) else { return [] }
        let text = input as NSString
        let matches = regex.matches(in: input, range: NSRange(location: 0, length: text.length))

        return matches.enumerated().compactMap { offset, match in
            let key = text.substring(with: match.range(at: 1))
            // Logging metadata, not part of the event
            guard key != "threadMain" else { return nil }

            let start = match.range.location + match.range.length
            let end = offset + 1 < matches.count ? matches[offset + 1].range.location : text.length
            let value = text.substring(with: NSRange(location: start, length: end - start))
                .trimmingCharacters(in: .whitespaces)
            guard value.hasSuffix("]") else { return nil }

            return makeJSONField(key: key, value: String(value.dropLast()))
        }
    }

    /// Builds a field for `value`, expanding JSON objects and arrays into children.
    /// Values that are not JSON (`select_content`, `5.7.0`) are kept as plain text.
    private static func makeJSONField(key: String, value: String) -> ParsedField {
        guard value.hasPrefix("{") || value.hasPrefix("["),
              let data = value.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return ParsedField(key: key, value: value)
        }
        return makeField(key: key, json: json, text: value)
    }

    /// Builds a field from a decoded JSON value. `text` is the value as logged, when known.
    private static func makeField(key: String, json: Any, text: String? = nil) -> ParsedField {
        switch json {
        case let object as [String: Any]:
            // JSON objects are unordered: sort the keys so the same event always reads the same
            let children = object.keys.sorted().map { makeField(key: $0, json: object[$0] as Any) }
            return ParsedField(key: key, value: text ?? jsonText(json), kind: .object, children: children)
        case let array as [Any]:
            // List elements have no key of their own: index them as [0], [1], ...
            let children = array.enumerated().map { makeField(key: "[\($0.offset)]", json: $0.element) }
            return ParsedField(key: key, value: text ?? jsonText(json), kind: .list, children: children)
        case let string as String:
            return ParsedField(key: key, value: string)
        case let number as NSNumber:
            let isBool = CFGetTypeID(number) == CFBooleanGetTypeID()
            return ParsedField(key: key, value: isBool ? (number.boolValue ? "true" : "false") : number.stringValue)
        default:
            return ParsedField(key: key, value: "null")
        }
    }

    /// Re-serializes a nested JSON container, for the value of a field that was not logged on its own
    private static func jsonText(_ json: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }
}

extension LogEntry.LogLevel {
    /// Maps an iOS unified logging level, as printed by `idevicesyslog` (`<Notice>`), to a level
    static func fromIOS(_ name: String) -> LogEntry.LogLevel {
        switch name {
        case "Debug": return .debug
        case "Info", "Notice": return .info
        case "Warning": return .warning
        case "Error": return .error
        case "Fault", "Critical", "Alert", "Emergency": return .fatal
        default: return .unknown
        }
    }
}
