//
//  LogCatAndroidTests.swift
//  LogCatAndroidTests
//
//  Created by Mikhail on 27/05/2025.
//

import Testing
@testable import LogCatAndroid

/// A build of the iOS catalog, by bundle identifier
private func build(_ id: String) -> IOSAppBuild {
    IOSAppBuild.build(withID: id)!
}

// MARK: - Android

struct AndroidLogParsingTests {

    @Test func parsesLogcatLines() {
        let line = "10-08 14:57:14.048  1234  5678 I Analytics: LogDomainModel(id=abc, event=screen_view, value={screen=home})"
        let entry = LogEntry.parse(line: line, index: 0)

        #expect(entry.timestamp == "10-08 14:57:14.048")
        #expect(entry.pid == "1234")
        #expect(entry.tid == "5678")
        #expect(entry.level == .info)
        #expect(entry.tags == ["Analytics"])
        #expect(entry.eventName == "screen_view")
        #expect(entry.payloadId == "abc")
        #expect(LogEntry.extractMessage(from: line) == "LogDomainModel(id=abc, event=screen_view, value={screen=home})")
        #expect(AppPackage.photoPrint.matches(line: line))
        #expect(!AppPackage.pictadroid.matches(line: line))
    }

    @Test func matchesPictadroidEventMessages() {
        let line = "10-08 14:57:14.048  1234  5678 D Firebase: event=screen_view params={screen_name=home}"
        #expect(AppPackage.pictadroid.matches(line: line))
        #expect(LogEntry.parse(line: line, index: 0).eventName == "screen_view")
    }

    @Test func iOSLinesDoNotMatchAndroidApps() {
        let line = "Oct  7 14:03:21.000000 Picta[77] <Notice>: event=screen_view params={screen_name=home}"
        #expect(LogEntry.extractMessage(from: line) == nil)
        #expect(!AppPackage.pictadroid.matches(line: line))
    }

    @Test func extractsPidsFromPs() {
        let output = """
        PID NAME
        4242 com.pictarine.photoprint
        4243 com.pictarine.photoprint:remote
        4244 com.pictarine.photoprintx
        """
        #expect(AndroidLogManager.pids(in: output, matching: "com.pictarine.photoprint") == ["4242", "4243"])
    }
}

// MARK: - iOS

struct IOSLogParsingTests {

    /// Captured from Picta (TestFlight) through `idevicesyslog`
    let pictaLine = #"Oct  8 14:57:14.048212 Picta[15846] <Info>: 📝: register - logId=[select_content] parameters=[{"content_name":"back","content_type":"button","item_id":"custom-retro-print-4x6","screen_class":"product_page"}] eventVersion=[5.7.0] threadMain=[false]"#

    @Test func parsesAPictaAnalyticsLine() throws {
        let entry = LogEntry.parse(line: pictaLine, index: 3)

        #expect(entry.timestamp == "10-08 14:57:14.048")
        #expect(entry.pid == "15846")
        #expect(entry.tid == "")
        #expect(entry.level == .info)
        #expect(entry.tags == ["Picta"])
        #expect(entry.index == 3)
        #expect(entry.message.hasPrefix("📝: register - logId=[select_content]"))
        #expect(entry.eventName == "select_content")

        #expect(entry.parsedFields.map(\.key) == ["logId", "parameters", "eventVersion"])
        let parameters = try #require(entry.parsedFields.first { $0.key == "parameters" })
        #expect(parameters.kind == .object)
        #expect(parameters.children.map(\.key) == ["content_name", "content_type", "item_id", "screen_class"])
        #expect(parameters.children.first?.value == "back")
        #expect(entry.parsedFields.last?.value == "5.7.0")
    }

    @Test func parsesTheImageOfDebugBuildsAndSystemProcesses() {
        let debug = LogEntry.parse(
            line: #"Oct 18 09:01:02.000001 Picta(Picta.debug.dylib)[1234] <Notice>: 📝: register - logId=[screen_view] parameters=[{"screen_name":"home"}] eventVersion=[3.1.0] threadMain=[true]"#,
            index: 0
        )
        #expect(debug.timestamp == "10-18 09:01:02.000")
        #expect(debug.tags == ["Picta"])
        #expect(debug.pid == "1234")
        #expect(debug.level == .info)
        #expect(debug.eventName == "screen_view")

        let system = LogEntry.parse(
            line: "Oct  8 14:48:56.821996 audiomxd(AudioToolbox)[124] <Debug>:                AQMEIO.cpp:224   Audio device started",
            index: 0
        )
        #expect(system.tags == ["AudioToolbox"])
        #expect(system.pid == "124")
        #expect(system.level == .debug)
        #expect(system.parsedFields.isEmpty)
    }

    @Test func parsesAppleLabPayloadsWithNestedArrays() throws {
        let entry = LogEntry.parse(
            line: #"Oct  8 15:00:00.100000 Walgreens[42] <Info>: 📝: send - logId=[Viewed Category] parameters=[{"items":[{"itemId":"4x6","quantity":2}],"isGift":false,"price":4.99,"coupon":null}] buildNumber=[1234]"#,
            index: 0
        )

        #expect(entry.eventName == "Viewed Category")
        #expect(entry.parsedFields.last?.key == "buildNumber")
        #expect(entry.parsedFields.last?.value == "1234")

        let parameters = try #require(entry.parsedFields.first { $0.key == "parameters" })
        let values = Dictionary(uniqueKeysWithValues: parameters.children.map { ($0.key, $0) })
        #expect(values["isGift"]?.value == "false")
        #expect(values["price"]?.value == "4.99")
        #expect(values["coupon"]?.value == "null")

        let items = try #require(values["items"])
        #expect(items.kind == .list)
        #expect(items.children.first?.key == "[0]")
        #expect(items.children.first?.children.map(\.key) == ["itemId", "quantity"])
        #expect(items.children.first?.children.last?.value == "2")
    }

    @Test func mapsIOSLevels() {
        #expect(LogEntry.LogLevel.fromIOS("Notice") == .info)
        #expect(LogEntry.LogLevel.fromIOS("Error") == .error)
        #expect(LogEntry.LogLevel.fromIOS("Fault") == .fatal)
        #expect(LogEntry.LogLevel.fromIOS("Whatever") == .unknown)
    }

    @Test func extractsTheIOSProcess() {
        #expect(LogEntry.extractIOSProcess(from: pictaLine) == "Picta")
        #expect(LogEntry.extractIOSProcess(from: "Oct 18 09:01:02.000001 Picta(Picta.debug.dylib)[1234] <Info>: x") == "Picta")
        #expect(LogEntry.extractIOSProcess(from: "[connected:00008140-001258100163001C]") == nil)
    }

    @Test func matchesIOSLinesPerApp() {
        #expect(build("com.pictarine.picta.ios").isAnalyticsLine(pictaLine))
        // The integration build shares the process: PIDs tell them apart, not the line
        #expect(build("com.pictarine.picta.ios.int").isAnalyticsLine(pictaLine))
        #expect(!build("com.pictarine.Photo-Print").isAnalyticsLine(pictaLine))

        let walgreens = #"Oct  8 15:00:00.100000 Walgreens[42] <Info>: 📝: send - logId=[x] parameters=[{}] buildNumber=[1]"#
        #expect(build("com.pictarine.Photo-Print").isAnalyticsLine(walgreens))
        #expect(!build("com.pictarine.Photo-Print.cvs").isAnalyticsLine(walgreens))

        let networkLog = "Oct  8 14:57:04.381356 Picta[15846] <Info>: ✈️: pathUpdate - status=[connected] threadMain=[false]"
        #expect(!build("com.pictarine.picta.ios").isAnalyticsLine(networkLog))
        #expect(!build("com.pictarine.picta.ios").isAnalyticsLine("[connected:00008140-001258100163001C]"))
    }

    @Test func keepsOnlyAnalyticsOfTheSelectedApp() {
        let picta = build("com.pictarine.picta.ios.int")
        let networkLog = "Oct  8 14:57:04.381356 Picta[15846] <Info>: ✈️: pathUpdate - status=[connected] threadMain=[false]"
        let walgreens = #"Oct  8 15:00:00.100000 Walgreens[42] <Info>: 📝: send - logId=[x] parameters=[{}] buildNumber=[1]"#

        #expect(IOSLogManager.shouldKeep(line: pictaLine, build: picta))
        #expect(!IOSLogManager.shouldKeep(line: networkLog, build: picta))
        #expect(!IOSLogManager.shouldKeep(line: walgreens, build: picta))
        // "All apps" keeps the analytics of every known app
        #expect(IOSLogManager.shouldKeep(line: walgreens, build: nil))
        #expect(!IOSLogManager.shouldKeep(line: networkLog, build: nil))
    }

    @Test func narrowsTheStreamDownOnTheDevice() {
        let usb = Device(id: "UDID", name: "iPhone", platform: .ios)
        #expect(IOSLogManager.syslogArguments(device: usb, build: build("com.pictarine.picta.ios.int"))
                == ["-u", "UDID", "--no-colors", "-p", "Picta", "-m", "logId=["])

        let wifi = Device(id: "UDID", name: "iPhone", platform: .ios, isWireless: true)
        #expect(IOSLogManager.syslogArguments(device: wifi, build: nil)
                == ["-n", "-u", "UDID", "--no-colors", "-p", "Picta|Walgreens|CVS", "-m", "logId=["])
        #expect(wifi.displayName == "iPhone · Wi-Fi")
    }

    @Test func listsUDIDsOnce() {
        let output = "00008140-001258100163001C\n00008150-000C0CC614F0401C\n00008140-001258100163001C\n\n"
        #expect(IOSLogManager.udids(in: output) == ["00008140-001258100163001C", "00008150-000C0CC614F0401C"])
        #expect(IOSLogManager.udids(in: nil).isEmpty)
    }

    @Test func attributesProcessesToTheirAppBundle() {
        let root = "file:///private/var/containers/Bundle/Application"
        let apps: [String: Any] = ["apps": [
            ["bundleIdentifier": "com.pictarine.picta.ios", "url": "\(root)/A9E1/Picta.app/"],
            ["bundleIdentifier": "com.pictarine.picta.ios.int", "url": "\(root)/7D06/Picta.app/"],
        ]]
        let processes: [String: Any] = ["runningProcesses": [
            ["processIdentifier": 11101, "executable": "\(root)/A9E1/Picta.app/Picta"],
            ["processIdentifier": 11371, "executable": "\(root)/7D06/Picta.app/Picta"],
            ["processIdentifier": 11400, "executable": "\(root)/7D06/Picta.app/PlugIns/Widget.appex/Widget"],
            ["processIdentifier": 35, "executable": "file:///usr/libexec/logd"],
        ]]

        let bundleIDs = ProcessAttribution.bundleIdentifiers(apps: apps, processes: processes)
        #expect(bundleIDs == [
            "11101": "com.pictarine.picta.ios",
            "11371": "com.pictarine.picta.ios.int",
            "11400": "com.pictarine.picta.ios.int",
            "35": "",
        ])
    }

    @Test func extractsPidsFromThePidList() {
        let output = "1 launchd\n33 UserEventAgent\n15846 Picta\n520 cloudphotod\n77 CVS\n"
        #expect(IOSLogManager.pids(inPidList: output, matching: ["Picta"]) == ["15846"])
        #expect(IOSLogManager.pids(inPidList: output, matching: ["Walgreens", "CVS"]) == ["77"])
        #expect(IOSLogManager.pids(inPidList: output, matching: ["Glance"]).isEmpty)
    }
}

struct IOSAppBuildTests {

    @Test func groupsTheBuildsByApp() {
        let groups = IOSAppBuild.appGroups
        #expect(groups.map(\.appName) == ["Picta", "Walgreens", "CVS"])
        #expect(groups[0].builds.map(\.menuLabel) == ["Prod · com.pictarine.picta.ios", "Int · com.pictarine.picta.ios.int"])
        #expect(groups[2].builds.map(\.id) == ["com.pictarine.Photo-Print.cvs", "com.pictarine.Photo-Print.cvs.int"])
    }

    @Test func labelsBuildsByEnvironment() {
        #expect(build("com.pictarine.picta.ios.int").shortLabel == "Picta · Int")
        #expect(build("com.pictarine.Photo-Print").shortLabel == "Walgreens · Prod")
        #expect(build("com.pictarine.Photo-Print.int").processName == "Walgreens")
        #expect(IOSAppBuild.build(withID: "com.example.unknown") == nil)
    }
}


// MARK: - Device comparison

struct LogComparatorTests {

    private func android(_ message: String) -> LogEntry {
        LogEntry.parse(line: "10-09 15:00:00.000  1234  5678 D Firebase: \(message)", index: 0)
    }

    private func ios(_ parameters: String, logId: String = "screen_view") -> LogEntry {
        LogEntry.parse(
            line: "Oct  9 15:00:00.000000 Picta[42] <Info>: 📝: register - logId=[\(logId)] parameters=[\(parameters)] eventVersion=[3.1.0] threadMain=[false]",
            index: 0
        )
    }

    @Test func matchingEventsAcrossPlatformsAreNotReported() {
        // Same event and parameters: only the envelope (logId, eventVersion…) and the ids differ
        let left = android("event=screen_view params={screen_name=home, screen_class=home, item_id=A1}")
        let right = ios(#"{"screen_class":"home","screen_name":"home","item_id":"B2"}"#)

        var comparator = LogComparator()
        #expect(comparator.add(left, from: .left) == nil)
        #expect(comparator.add(right, from: .right) == nil)
        #expect(comparator.pairedCount == 1)
        #expect(comparator.finish().isEmpty)
    }

    @Test func reportsDifferentValuesAndMissingFields() throws {
        let left = android("event=screen_view params={screen_name=home, screen_class=home, source=push}")
        let right = ios(#"{"screen_class":"Home","screen_name":"home","origin":"push"}"#)

        let mismatch = try #require(LogComparator.compare(left: left, right: right))
        #expect(mismatch.kind == .fieldsDiffer)
        #expect(mismatch.eventName == "screen_view")
        #expect(mismatch.differentValues == [.init(key: "screen_class", left: "home", right: "Home")])
        #expect(mismatch.onlyOnLeft == ["source"])
        #expect(mismatch.onlyOnRight == ["origin"])
    }

    @Test func ignoresTheValuesOfIDs() {
        #expect(LogComparator.isIDKey("id"))
        #expect(LogComparator.isIDKey("item_id"))
        #expect(LogComparator.isIDKey("orderId"))
        #expect(LogComparator.isIDKey("items[0].itemID"))
        #expect(!LogComparator.isIDKey("screen_name"))
        #expect(!LogComparator.isIDKey("paid"))

        // Nested ids too, but a missing id field is still a missing field
        let left = ios(#"{"items":[{"itemId":"4x6","quantity":2}]}"#, logId: "add_to_cart")
        let right = ios(#"{"items":[{"itemId":"5x7","quantity":2}],"cart_id":"x"}"#, logId: "add_to_cart")
        let mismatch = LogComparator.compare(left: left, right: right)
        #expect(mismatch?.differentValues.isEmpty == true)
        #expect(mismatch?.onlyOnRight == ["cart_id"])
    }

    @Test func flattensPhotoPrintPayloads() {
        let entry = LogEntry.parse(
            line: "10-09 15:00:00.000  1234  5678 D Analytics: LogDomainModel(id=abc, event=screen_view, value={screen=home, parameters={source=push}}, appVersion=1)",
            index: 0
        )
        // The log's own id, the event name and the app version are envelope, not event fields
        #expect(LogComparator.comparableFields(of: entry) == ["screen": "home", "source": "push"])
    }

    @Test func pairsEventsByNameInOrderAndReportsTheUnpaired() {
        var comparator = LogComparator()
        _ = comparator.add(android("event=screen_view params={screen_name=home}"), from: .left)
        _ = comparator.add(android("event=add_to_cart params={value=3}"), from: .left)
        // Pairs with the left `screen_view`, not with `add_to_cart` which came in between
        #expect(comparator.add(ios(#"{"screen_name":"home"}"#), from: .right) == nil)
        #expect(comparator.pairedCount == 1)

        let unpaired = comparator.finish()
        #expect(unpaired.map(\.eventName) == ["add_to_cart"])
        #expect(unpaired.first?.kind == .missingOnOtherSide)
        #expect(unpaired.first?.leftRawLine != nil && unpaired.first?.rightRawLine == nil)
    }
}

// MARK: - Detail order

struct DisplayFieldOrderTests {

    @Test func listsTheEventFirstThenAlphabetically() {
        let android = LogEntry.parse(
            line: "10-09 15:00:00.000  1234  5678 D Firebase: event=screen_view params={screen_name=home, Item10=b, item2=a}",
            index: 0
        )
        #expect(android.displayFields.map(\.key) == ["event", "params"])
        // Nested objects too, case-insensitive with numbers in natural order
        #expect(android.displayFields[1].children.map(\.key) == ["item2", "Item10", "screen_name"])

        let ios = LogEntry.parse(
            line: #"Oct  9 15:00:00.000000 Picta[42] <Info>: 📝: register - logId=[add_to_cart] parameters=[{"z":1,"items":[{"qty":2,"b":1},{"a":3}]}] eventVersion=[5.7.0] threadMain=[false]"#,
            index: 0
        )
        #expect(ios.displayFields.map(\.key) == ["logId", "eventVersion", "parameters"])
        let items = ios.displayFields[2].children.first { $0.key == "items" }
        // List items keep their order, the objects inside them are sorted
        #expect(items?.children.map(\.key) == ["[0]", "[1]"])
        #expect(items?.children.first?.children.map(\.key) == ["b", "qty"])
    }
}

// MARK: - Differences to the fix list

struct MismatchFixCandidateTests {

    @Test func splitsADifferenceIntoFixItems() throws {
        let left = LogEntry.parse(line: "10-09 15:00:00.000  1234  5678 D Firebase: event=screen_view params={screen_class=home, source=push}", index: 0)
        let right = LogEntry.parse(
            line: #"Oct  9 15:00:00.000000 Picta[42] <Info>: 📝: register - logId=[screen_view] parameters=[{"screen_class":"Home","origin":"deeplink"}] eventVersion=[3.1.0] threadMain=[false]"#,
            index: 0
        )
        let mismatch = try #require(LogComparator.compare(left: left, right: right))
        let candidates = mismatch.fixCandidates(leftName: "Pixel", rightName: "iPhone")

        #expect(candidates.map(\.fieldKey) == ["screen_class", "source", "origin"])
        #expect(candidates[0].side == .left)
        #expect(candidates[0].note == "screen_class differs: Pixel = home, iPhone = Home")
        // A field logged by one device points at that device's log, with its value there
        #expect(candidates[1].side == .left && candidates[1].fieldValue == "push")
        #expect(candidates[2].side == .right && candidates[2].fieldValue == "deeplink")
        #expect(candidates[2].note == "origin logged by iPhone but missing on Pixel")
        #expect(mismatch.entry(for: .right)?.pid == "42")
    }

    @Test func aMissingEventIsOneFixItem() {
        var comparator = LogComparator()
        _ = comparator.add(LogEntry.parse(line: "10-09 15:00:00.000  1234  5678 D Firebase: event=purchase params={value=3}", index: 0), from: .left)
        let mismatch = comparator.finish()[0]

        #expect(mismatch.fixCandidates(leftName: "Pixel", rightName: "iPhone") == [MismatchFixCandidate(
            kind: .missingEvent, side: .left, fieldKey: "event", fieldValue: "purchase",
            note: "Logged by Pixel but not by iPhone", label: "Only logged by Pixel"
        )])
    }
}

// MARK: - Ignored differences

struct CompareIgnoreRuleTests {

    private func mismatch() throws -> CompareMismatch {
        let left = LogEntry.parse(line: "10-09 15:00:00.000  1234  5678 D Firebase: event=screen_view params={screen_class=home, source=push, app_version=1}", index: 0)
        let right = LogEntry.parse(
            line: #"Oct  9 15:00:00.000000 Picta[42] <Info>: 📝: register - logId=[screen_view] parameters=[{"screen_class":"Home","origin":"deeplink","app_version":"2"}] eventVersion=[3.1.0] threadMain=[false]"#,
            index: 0
        )
        return try #require(LogComparator.compare(left: left, right: right))
    }

    @Test func ignoringAValueKeepsTheFieldPresenceCompared() throws {
        let filtered = try #require(try mismatch().applying([CompareIgnoreRule(kind: .value, key: "screen_class")]))
        #expect(filtered.differentValues.map(\.key) == ["app_version"])
        #expect(filtered.onlyOnLeft == ["source"])
    }

    @Test func ignoringAFieldHidesItsPresenceToo() throws {
        let filtered = try #require(try mismatch().applying([
            CompareIgnoreRule(kind: .field, key: "source"),
            CompareIgnoreRule(kind: .field, key: "origin", eventName: "screen_view"),
        ]))
        #expect(filtered.onlyOnLeft.isEmpty && filtered.onlyOnRight.isEmpty)
        #expect(filtered.differentValues.count == 2)
    }

    @Test func rulesLimitedToAnotherEventDoNotApply() throws {
        let original = try mismatch()
        #expect(original.applying([CompareIgnoreRule(kind: .value, key: "screen_class", eventName: "purchase")]) == original)
    }

    @Test func aFullyIgnoredDifferenceDisappears() throws {
        let rules = [
            CompareIgnoreRule(kind: .value, key: "screen_class"),
            CompareIgnoreRule(kind: .value, key: "app_version"),
            CompareIgnoreRule(kind: .field, key: "source"),
            CompareIgnoreRule(kind: .field, key: "origin"),
        ]
        #expect(try mismatch().applying(rules) == nil)
        #expect(try mismatch().applying([CompareIgnoreRule(kind: .event, key: "screen_view")]) == nil)
    }

    @Test func theStoreKeepsOneRuleOfEachKind() {
        let store = CompareIgnoreStore()
        let saved = store.rules
        defer {
            store.removeAll()
            saved.forEach(store.add)
        }
        store.removeAll()

        store.add(CompareIgnoreRule(kind: .value, key: "screen_class"))
        store.add(CompareIgnoreRule(kind: .value, key: "screen_class"))
        store.add(CompareIgnoreRule(kind: .value, key: "screen_class", eventName: "screen_view"))
        #expect(store.rules.count == 2)

        store.remove(store.rules[0])
        #expect(store.rules.map(\.scope) == ["in screen_view"])
    }
}
