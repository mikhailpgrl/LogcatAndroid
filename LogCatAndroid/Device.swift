//
//  Device.swift
//  LogCatAndroid
//

import Foundation

/// The kind of device logs are streamed from
enum DevicePlatform: String, Hashable {
    case android
    case ios

    var displayName: String {
        switch self {
        case .android: return "Android"
        case .ios: return "iOS"
        }
    }

    /// SF Symbol shown next to the device name
    var symbol: String {
        switch self {
        case .android: return "smartphone"
        case .ios: return "apple.logo"
        }
    }
}

/// A connected device logs can be streamed from
struct Device: Identifiable, Hashable {
    /// The adb serial (Android) or the UDID (iOS)
    let id: String
    /// Human readable name: the model on Android, the user-given name on iOS
    let name: String
    let platform: DevicePlatform
    /// Reached over the network (wireless debugging on Android, Wi-Fi sync on iOS) rather than USB
    var isWireless = false

    /// The name shown in the device picker
    var displayName: String {
        isWireless ? "\(name) · Wi-Fi" : name
    }
}
