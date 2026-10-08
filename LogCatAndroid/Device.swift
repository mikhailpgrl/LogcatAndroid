//
//  Device.swift
//  LogCatAndroid
//

import Foundation

/// A device logs can be streamed from: an Android device seen by adb, or an iPhone seen by libimobiledevice
struct Device: Identifiable, Hashable {
    enum Platform: Hashable {
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
            case .android: return "candybarphone"
            case .ios: return "iphone"
            }
        }
    }

    /// The adb serial (Android) or the UDID (iOS), used to target the device on the command line
    let id: String
    /// Human readable name: the iPhone's name when it could be resolved, otherwise the identifier
    let name: String
    let platform: Platform
}
