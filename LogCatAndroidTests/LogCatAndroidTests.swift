//
//  LogCatAndroidTests.swift
//  LogCatAndroidTests
//
//  Created by Mikhail on 27/05/2025.
//

import Testing
@testable import LogCatAndroid

struct LogCatAndroidTests {

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    }

}

// MARK: - iOS syslog parsing

struct IOSSyslogParsingTests {

    private let photoPrintLine = "Oct  7 14:03:21 Mikhails-iPhone PhotoPrint(Foundation)[1234] <Notice>: Analytics LogDomainModel(id=42, event=screen_view)"

    @Test func parsesTimestampPidTagAndMessage() throws {
        let entry = try #require(LogEntry.parseIOSSyslog(line: photoPrintLine, index: 3))

        #expect(entry.timestamp == "Oct  7 14:03:21")
        #expect(entry.pid == "1234")
        #expect(entry.tid.isEmpty)
        #expect(entry.tags == ["PhotoPrint"])
        #expect(entry.level == .info)
        #expect(entry.message == "Analytics LogDomainModel(id=42, event=screen_view)")
        #expect(entry.index == 3)
        #expect(entry.eventName == "screen_view")
        #expect(entry.payloadId == "42")
    }

    @Test func parsesLineWithoutLibrary() throws {
        let line = "Oct 17 09:00:01 iPhone Pictarine[88] <Error>: event=purchase params={value=3}"
        let entry = try #require(LogEntry.parseIOSSyslog(line: line, index: 0))

        #expect(entry.tags == ["Pictarine"])
        #expect(entry.pid == "88")
        #expect(entry.level == .error)
        #expect(entry.eventName == "purchase")
    }

    @Test(arguments: [
        ("Notice", LogEntry.LogLevel.info),
        ("Info", .info),
        ("Debug", .debug),
        ("Warning", .warning),
        ("Error", .error),
        ("Fault", .fatal),
        ("Whatever", .unknown),
    ])
    func mapsLevels(word: String, expected: LogEntry.LogLevel) throws {
        let line = "Oct  7 14:03:21 iPhone PhotoPrint[1] <\(word)>: hello"
        let entry = try #require(LogEntry.parseIOSSyslog(line: line, index: 0))
        #expect(entry.level == expected)
    }

    @Test func parseFallsBackToIOSFormat() {
        let entry = LogEntry.parse(line: photoPrintLine, index: 0)
        #expect(entry.pid == "1234")
        #expect(entry.tag == "PhotoPrint")
    }

    @Test func extractMessageSupportsIOSLines() {
        let line = "Oct  7 14:03:21 iPhone Pictarine(CoreFoundation)[77] <Notice>: event=screen_view params={screen_name=home}"
        #expect(LogEntry.extractMessage(from: line) == "event=screen_view params={screen_name=home}")
        #expect(AppPackage.pictadroid.matches(line: line))
    }

    @Test func androidLinesAreUnchanged() {
        let line = "10-07 14:03:21.123  1234  5678 I Analytics: LogDomainModel(id=1, event=open)"
        #expect(LogEntry.parseIOSSyslog(line: line, index: 0) == nil)
        let entry = LogEntry.parse(line: line, index: 0)
        #expect(entry.tid == "5678")
        #expect(entry.tag == "Analytics")
        #expect(LogEntry.extractMessage(from: line) == "LogDomainModel(id=1, event=open)")
    }

    @Test func syslogArgumentsFilterOnProcessNames() {
        #expect(ADBManager.syslogArguments(device: "UDID", package: .photoPrint)
                == ["--no-colors", "-u", "UDID", "-p", "PhotoPrint"])
        #expect(ADBManager.syslogArguments(device: nil, package: nil) == ["--no-colors"])
    }
}
