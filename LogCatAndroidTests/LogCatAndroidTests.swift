//
//  LogCatAndroidTests.swift
//  LogCatAndroidTests
//
//  Created by Mikhail on 27/05/2025.
//

import Testing
@testable import LogCatAndroid

/// A build of the catalog, by bundle identifier or package name
private func build(_ id: String) -> AppBuild {
    AppBuild.build(withID: id)!
}

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

    @Test func keepsEveryLogOfTheAppInAllLogsMode() {
        let picta = build("com.pictarine.picta.ios.int")
        let networkLog = "Oct  8 14:57:04.381356 Picta[15846] <Info>: ✈️: pathUpdate - status=[connected] threadMain=[false]"
        let frameworkLog = "Oct  8 14:57:04.400000 Picta(CFNetwork)[15846] <Debug>: Task <1> finished"
        let otherApp = "Oct  8 14:57:04.500000 Walgreens[42] <Info>: something"

        #expect(!ADBManager.shouldKeep(line: networkLog, build: picta, platform: .ios, mode: .analytics))
        #expect(ADBManager.shouldKeep(line: pictaLine, build: picta, platform: .ios, mode: .analytics))

        #expect(ADBManager.shouldKeep(line: networkLog, build: picta, platform: .ios, mode: .all))
        #expect(ADBManager.shouldKeep(line: frameworkLog, build: picta, platform: .ios, mode: .all))
        #expect(!ADBManager.shouldKeep(line: otherApp, build: picta, platform: .ios, mode: .all))
        #expect(ADBManager.shouldKeep(line: otherApp, build: nil, platform: .ios, mode: .all))
        #expect(!ADBManager.shouldKeep(line: "[connected:00008140-001258100163001C]", build: nil, platform: .ios, mode: .all))

        #expect(LogEntry.parse(line: frameworkLog, index: 0).tags == ["CFNetwork"])
        #expect(LogEntry.parse(line: networkLog, index: 0).parsedFields.map(\.key) == ["status"])
    }

    @Test func listsUDIDsOnce() {
        let output = "00008140-001258100163001C\n00008150-000C0CC614F0401C\n00008140-001258100163001C\n\n"
        #expect(IOSBridge.udids(in: output) == ["00008140-001258100163001C", "00008150-000C0CC614F0401C"])
        #expect(IOSBridge.udids(in: nil).isEmpty)
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
        #expect(IOSBridge.pids(inPidList: output, matching: ["Picta"]) == ["15846"])
        #expect(IOSBridge.pids(inPidList: output, matching: ["Walgreens", "CVS"]) == ["77"])
        #expect(IOSBridge.pids(inPidList: output, matching: ["Glance"]).isEmpty)
    }
}

struct AndroidLogParsingTests {

    @Test func stillParsesLogcatLines() {
        let entry = LogEntry.parse(
            line: "10-08 14:57:14.048  1234  5678 I Analytics: LogDomainModel(id=abc, event=screen_view, value={screen=home})",
            index: 0
        )

        #expect(entry.timestamp == "10-08 14:57:14.048")
        #expect(entry.pid == "1234")
        #expect(entry.tid == "5678")
        #expect(entry.level == .info)
        #expect(entry.tags == ["Analytics"])
        #expect(entry.eventName == "screen_view")
        #expect(entry.payloadId == "abc")
        #expect(build("com.pictarine.photoprint").isAnalyticsLine(entry.rawLine))
        #expect(!build("com.pictarine.picta.android").isAnalyticsLine(entry.rawLine))
    }

    @Test func parsesAdbDevices() {
        let output = """
        List of devices attached
        R58M123ABC             device usb:1-1 product:beyond1 model:SM_G973F device:beyond1 transport_id:1
        emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 transport_id:2
        0123456789ABCDEF       unauthorized usb:1-2 transport_id:3
        ZY22ABC\tdevice
        192.168.1.20:5555      device product:shiba model:Pixel_8 device:shiba transport_id:4
        adb-28241FDH2000AB-x1y2z3._adb-tls-connect._tcp device product:shiba model:Pixel_8 transport_id:5

        """

        let devices = AndroidBridge.devices(in: output)
        #expect(devices.map(\.id) == ["R58M123ABC", "emulator-5554", "ZY22ABC", "192.168.1.20:5555",
                                       "adb-28241FDH2000AB-x1y2z3._adb-tls-connect._tcp"])
        #expect(devices.map(\.name) == ["SM G973F", "sdk gphone64 arm64", "ZY22ABC", "Pixel 8", "Pixel 8"])
        #expect(devices.map(\.isWireless) == [false, false, false, true, true])
        #expect(devices[3].displayName == "Pixel 8 · Wi-Fi")
        #expect(devices.allSatisfy { $0.platform == .android })
    }

    @Test func extractsPidsFromPs() {
        let output = """
        PID NAME
        4242 com.pictarine.photoprint
        4243 com.pictarine.photoprint:remote
        4244 com.pictarine.photoprintx
        """
        #expect(AndroidBridge.pids(in: output, matching: "com.pictarine.photoprint") == ["4242", "4243"])
    }
}

struct AppBuildTests {

    @Test func groupsTheBuildsOfEachPlatformByApp() {
        let ios = AppBuild.appGroups(for: .ios)
        #expect(ios.map(\.appName) == ["Picta", "Walgreens", "CVS"])
        #expect(ios[0].builds.map(\.menuLabel) == ["Prod · com.pictarine.picta.ios", "Int · com.pictarine.picta.ios.int"])
        #expect(ios[2].builds.map(\.id) == ["com.pictarine.Photo-Print.cvs", "com.pictarine.Photo-Print.cvs.int"])
        #expect(ios.flatMap(\.builds).allSatisfy { $0.platform == .ios })

        let android = AppBuild.appGroups(for: .android)
        #expect(android.map(\.appName) == ["PhotoPrint", "Pictadroid"])
        #expect(android[0].builds.map(\.id) == ["com.pictarine.photoprint", "com.pictarine.photoprint.debug"])
        #expect(android[1].builds.count == 4)
    }

    @Test func labelsBuildsByEnvironment() {
        #expect(build("com.pictarine.picta.ios.int").shortLabel == "Picta · Int")
        #expect(build("com.pictarine.photoprint").shortLabel == "PhotoPrint · Prod")
        #expect(build("com.pictarine.photoprint.debug").environment == .integration)
        #expect(build("com.pictarine.Photo-Print.int").processName == "Walgreens")
        #expect(AppBuild.build(withID: "com.example.unknown") == nil)
    }
}
