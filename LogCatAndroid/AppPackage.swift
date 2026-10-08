//
//  AppPackage.swift
//  LogCatAndroid
//

import Foundation

/// The Pictarine apps whose logs can be inspected, with their Android and iOS identities
enum AppPackage: String, CaseIterable, Identifiable {
    case photoPrint = "com.pictarine.photoprint"
    case pictadroid = "com.pictarine.pictadroid"

    var id: String { rawValue }

    /// Short, human readable name shown in the picker
    var displayName: String {
        switch self {
        case .photoPrint: return "PhotoPrint"
        case .pictadroid: return "Pictadroid"
        }
    }

    /// The Android package identifiers this app runs under (release and debug builds),
    /// used to resolve the running process PIDs.
    /// The raw value stays stable for persistence; the actual identifiers live here.
    var packageNames: [String] {
        switch self {
        case .photoPrint:
            return ["com.pictarine.photoprint", "com.pictarine.photoprint.debug"]
        case .pictadroid:
            return ["com.pictarine.picta.android", "com.pictarine.picta.android.debug",
                    "com.pictarine.pictadroid", "com.pictarine.pictadroid.debug"]
        }
    }

    /// The primary Android package identifier, shown in the UI
    var packageName: String { packageNames[0] }

    /// The process names this app can run under, one per package identifier
    var processNames: [String] { packageNames }

    /// The executable names of the iOS counterparts, which is what the iOS syslog shows as process
    var iosProcessNames: [String] {
        switch self {
        case .photoPrint:
            // AppleLab's white-label retailer apps
            return ["Walgreens", "CVS"]
        case .pictadroid:
            // picta-ios
            return ["Picta"]
        }
    }

    /// The production bundle identifier of the iOS counterpart (`.int` builds are matched too),
    /// shown in the UI
    var iosBundleIdentifier: String {
        switch self {
        case .photoPrint: return "com.pictarine.Photo-Print"
        case .pictadroid: return "com.pictarine.picta.ios"
        }
    }

    /// Describes what is matched on `platform`, shown under the picker
    func identifierSummary(for platform: DevicePlatform) -> String {
        switch platform {
        case .android: return "\(packageName) (+ debug)"
        case .ios: return "\(iosProcessNames.joined(separator: ", ")) · \(iosBundleIdentifier)"
        }
    }

    /// Whether a raw log line from a `platform` device is one of the analytics logs this app emits
    func matches(line: String, platform: DevicePlatform) -> Bool {
        switch (platform, self) {
        case (.android, .photoPrint):
            // PhotoPrint logs analytics through a dedicated "Analytics" tag
            return line.contains("Analytics")
        case (.android, .pictadroid):
            // Pictadroid logs analytics as plain `event=...` messages
            return LogEntry.extractMessage(from: line)?.hasPrefix("event=") == true
        case (.ios, _):
            // Both iOS codebases log analytics as `logId=[name] parameters=[{json}] ...`
            return line.contains(IOSBridge.analyticsMarker) && isIOSLineFromApp(line)
        }
    }

    /// Whether a raw iOS log line was emitted by one of this app's processes
    func isIOSLineFromApp(_ line: String) -> Bool {
        guard let process = LogEntry.extractIOSProcess(from: line) else { return false }
        return iosProcessNames.contains(process)
    }
}
