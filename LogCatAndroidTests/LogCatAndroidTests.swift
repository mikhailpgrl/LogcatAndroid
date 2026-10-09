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

// TEMP live probe
struct LiveIOSProbe {
    @Test func appWiringWithBothDevices() async throws {
        let (devices, android, ios) = await MainActor.run { () -> (DeviceManager, AndroidLogManager, IOSLogManager) in
            let android = AndroidLogManager()
            let ios = IOSLogManager()
            let devices = DeviceManager(android: android, ios: ios)
            devices.refreshDevices()
            return (devices, android, ios)
        }
        try await Task.sleep(for: .seconds(4))
        await MainActor.run {
            print("PROBE devices=\(devices.connectedDevices.map { "\($0.platform.displayName):\($0.id)" }) selected=\(devices.selectedDeviceID ?? "nil") androidRunning=\(android.isLogcatRunning)")
            print("PROBE iosBuild=\(ios.selectedBuild?.id ?? "all apps")")
            // Like the user: pick the iPhone, then press Start on the displayed manager
            devices.selectedDeviceID = devices.connectedDevices.first { $0.platform == .ios }?.id
            let logs: LogStreamManager = devices.selectedPlatform == .ios ? ios : android
            print("PROBE platform=\(devices.selectedPlatform.displayName) logsIsIOS=\(logs === ios) iosDevice=\(ios.selectedDevice?.id ?? "nil")")
            logs.startLogcat()
        }
        for i in 1...12 {
            try await Task.sleep(for: .seconds(10))
            await MainActor.run {
                let shown = ios.logEntries.filter { e in ios.attributedPids.map { $0.contains(e.pid) } ?? true }
                print("PROBE t=\(i*10)s iosRunning=\(ios.isLogcatRunning) androidRunning=\(android.isLogcatRunning) entries=\(ios.logEntries.count) shown=\(shown.count) pids=\(ios.buildPids) attributed=\((ios.attributedPids ?? []).sorted())")
            }
        }
        await MainActor.run { ios.stopLogcat(); android.stopLogcat() }
    }
}
