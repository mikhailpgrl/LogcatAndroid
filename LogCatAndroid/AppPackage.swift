//
//  AppPackage.swift
//  LogCatAndroid
//

import Foundation

/// The Android app packages whose logs can be inspected
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

    /// Whether a raw logcat line is one of the analytics logs this app emits
    func matches(line: String) -> Bool {
        switch self {
        case .photoPrint:
            // PhotoPrint logs analytics through a dedicated "Analytics" tag
            return line.contains("Analytics")
        case .pictadroid:
            // Pictadroid logs analytics as plain `event=...` messages
            return LogEntry.extractMessage(from: line)?.hasPrefix("event=") == true
        }
    }
}
