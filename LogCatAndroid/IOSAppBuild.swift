//
//  IOSAppBuild.swift
//  LogCatAndroid
//

import Foundation

/// One build of a Pictarine iOS app, identified by its bundle identifier.
/// The Android apps are described by `AppPackage`.
struct IOSAppBuild: Identifiable, Hashable {
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

    /// The text every analytics line of the iOS apps holds, from the Pictalytics console logger:
    /// `logId=[name] parameters=[{json}] ...`. Also used to filter the stream (`idevicesyslog -m`).
    static let analyticsMarker = "logId=["

    /// The bundle identifier
    let id: String
    /// The app's name, shared by its builds
    let appName: String
    let environment: Environment
    /// The executable the build runs as, which is what the syslog shows as process.
    /// The builds of an app share it: they are told apart by PID.
    let processName: String

    /// The label of the closed picker, e.g. "Picta · Int"
    var shortLabel: String {
        "\(appName) · \(environment.shortName)"
    }

    /// The label in the picker's menu, under the app's section, e.g. "Int · com.pictarine.picta.ios.int"
    var menuLabel: String {
        "\(environment.shortName) · \(id)"
    }

    /// Whether a raw syslog line is one of this build's analytics events (or another build of its app's)
    func isAnalyticsLine(_ line: String) -> Bool {
        line.contains(Self.analyticsMarker) && isLineFromProcess(line)
    }

    /// Whether a raw syslog line was emitted by this build's process (or another build of its app)
    func isLineFromProcess(_ line: String) -> Bool {
        LogEntry.extractIOSProcess(from: line) == processName
    }
}

// MARK: - Catalog

extension IOSAppBuild {
    /// Every known build, in picker order
    static let all: [IOSAppBuild] = [
        // picta-ios
        builds("Picta", "com.pictarine.picta.ios", process: "Picta"),
        // AppleLab's white-label retailer apps
        builds("Walgreens", "com.pictarine.Photo-Print", process: "Walgreens"),
        builds("CVS", "com.pictarine.Photo-Print.cvs", process: "CVS"),
    ].flatMap { $0 }

    /// The builds grouped by app, in catalog order, for the picker's sections
    static var appGroups: [(appName: String, builds: [IOSAppBuild])] {
        var groups: [(appName: String, builds: [IOSAppBuild])] = []
        for build in all {
            if let index = groups.firstIndex(where: { $0.appName == build.appName }) {
                groups[index].builds.append(build)
            } else {
                groups.append((build.appName, [build]))
            }
        }
        return groups
    }

    static func build(withID id: String) -> IOSAppBuild? {
        all.first { $0.id == id }
    }

    /// A production bundle and its `.int` integration build, which share their executable
    private static func builds(_ appName: String, _ bundleID: String, process: String) -> [IOSAppBuild] {
        [
            IOSAppBuild(id: bundleID, appName: appName, environment: .production, processName: process),
            IOSAppBuild(id: "\(bundleID).int", appName: appName, environment: .integration, processName: process),
        ]
    }
}
