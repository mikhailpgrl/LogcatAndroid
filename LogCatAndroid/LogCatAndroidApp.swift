//
//  LogCatAndroidApp.swift
//  LogCatAndroid
//
//  Created by Mikhail on 27/05/2025.
//

import SwiftUI

@main
struct LogCatAndroidApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }

        // Two devices' logs side by side, opened from the device section when two devices are connected
        WindowGroup("Compare Devices", id: "compare", for: CompareRequest.self) { $request in
            if let request {
                CompareView(request: request)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Before any window is shown, so a dark theme does not open as a light window first
        ThemeManager.applyAppearance(of: ThemeManager.savedTheme)
    }
}
