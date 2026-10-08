//
//  AppBuild.swift
//  LogCatAndroid
//

import Foundation

/// How an app logs its analytics events, to recognize them among its other logs
enum AnalyticsFormat {
    /// PhotoPrint (Android): a dedicated `Analytics` logcat tag
    case analyticsTag
    /// Pictadroid (Android): plain `event=...` messages
    case eventMessage
    /// The iOS apps: `logId=[name] parameters=[{json}] ...`, from the Pictalytics console logger
    case pictalytics

    /// The text every analytics line of the iOS apps holds, also used to filter the stream
    static let pictalyticsMarker = "logId=["

    func matches(line: String) -> Bool {
        switch self {
        case .analyticsTag:
            return line.contains("Analytics")
        case .eventMessage:
            return LogEntry.extractMessage(from: line)?.hasPrefix("event=") == true
        case .pictalytics:
            return line.contains(Self.pictalyticsMarker)
        }
    }
}

/// One build of a Pictarine app: a bundle identifier on iOS, a package name on Android
struct AppBuild: Identifiable, Hashable {
    enum Environment: Hashable {
        case production
        case integration

        var shortName: String {
            switch self {
            case .production: return "Prod"
            case .integration: return "Int"
            }
        }
    }

    /// The bundle identifier (iOS) or package name (Android)
    let id: String
    /// The app's name, shared by its builds
    let appName: String
    let environment: Environment
    let platform: DevicePlatform
    /// The process the build runs as. On iOS it is the executable, which the builds of an app
    /// share: they are told apart by PID. On Android it is the package name.
    let processName: String
    let analyticsFormat: AnalyticsFormat

    /// The label of the closed picker, e.g. "Picta · Int"
    var shortLabel: String {
        "\(appName) · \(environment.shortName)"
    }

    /// The label in the picker's menu, under the app's section, e.g. "Int · com.pictarine.picta.ios.int"
    var menuLabel: String {
        "\(environment.shortName) · \(id)"
    }

    /// Whether a raw log line is one of this build's analytics events. On iOS, the line must also
    /// come from the build's process; on Android the PID filter takes care of that.
    func isAnalyticsLine(_ line: String) -> Bool {
        guard analyticsFormat.matches(line: line) else { return false }
        return platform == .android || isIOSLineFromProcess(line)
    }

    /// Whether a raw iOS log line was emitted by this build's process (or another build of its app)
    func isIOSLineFromProcess(_ line: String) -> Bool {
        LogEntry.extractIOSProcess(from: line) == processName
    }
}

// MARK: - Catalog

extension AppBuild {
    /// Every known build, in picker order
    static let all: [AppBuild] = [
        // Android: `.debug` packages are the integration builds
        android("PhotoPrint", "com.pictarine.photoprint", .analyticsTag),
        android("Pictadroid", "com.pictarine.picta.android", .eventMessage),
        android("Pictadroid", "com.pictarine.pictadroid", .eventMessage),
        // iOS: picta-ios
        ios("Picta", "com.pictarine.picta.ios", process: "Picta"),
        // iOS: AppleLab's white-label retailer apps
        ios("Walgreens", "com.pictarine.Photo-Print", process: "Walgreens"),
        ios("CVS", "com.pictarine.Photo-Print.cvs", process: "CVS"),
    ].flatMap { $0 }

    static func builds(for platform: DevicePlatform) -> [AppBuild] {
        all.filter { $0.platform == platform }
    }

    /// The builds of `platform` grouped by app, in catalog order, for the picker's sections
    static func appGroups(for platform: DevicePlatform) -> [(appName: String, builds: [AppBuild])] {
        var groups: [(appName: String, builds: [AppBuild])] = []
        for build in builds(for: platform) {
            if let index = groups.firstIndex(where: { $0.appName == build.appName }) {
                groups[index].builds.append(build)
            } else {
                groups.append((build.appName, [build]))
            }
        }
        return groups
    }

    static func build(withID id: String) -> AppBuild? {
        all.first { $0.id == id }
    }

    /// A production package and its `.debug` integration build
    private static func android(_ appName: String, _ package: String, _ format: AnalyticsFormat) -> [AppBuild] {
        [
            AppBuild(id: package, appName: appName, environment: .production, platform: .android,
                     processName: package, analyticsFormat: format),
            AppBuild(id: "\(package).debug", appName: appName, environment: .integration, platform: .android,
                     processName: "\(package).debug", analyticsFormat: format),
        ]
    }

    /// A production bundle and its `.int` integration build, which share their executable
    private static func ios(_ appName: String, _ bundleID: String, process: String) -> [AppBuild] {
        [
            AppBuild(id: bundleID, appName: appName, environment: .production, platform: .ios,
                     processName: process, analyticsFormat: .pictalytics),
            AppBuild(id: "\(bundleID).int", appName: appName, environment: .integration, platform: .ios,
                     processName: process, analyticsFormat: .pictalytics),
        ]
    }
}
