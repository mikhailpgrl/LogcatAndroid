//
//  CaptureMode.swift
//  LogCatAndroid
//

import Foundation

/// Which logs of the followed apps are captured
enum CaptureMode: String, CaseIterable, Identifiable {
    /// Only the analytics events (see `AppPackage.matches(line:platform:)`)
    case analytics
    /// Every log line emitted by the apps' processes
    case all

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .analytics: return "Analytics"
        case .all: return "All logs"
        }
    }
}
