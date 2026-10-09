//
//  DeviceManager.swift
//  LogCatAndroid
//

import AppKit

/// Lists the Android and iOS devices plugged in and hands the selected one to its platform's
/// log manager. Android and iOS logs are streamed separately (`AndroidLogManager`, `IOSLogManager`):
/// only the manager of the selected device's platform runs at a time.
final class DeviceManager: ObservableObject {
    /// Android (adb) and iOS (libimobiledevice) devices currently connected
    @Published private(set) var connectedDevices: [Device] = []

    /// The `Device.id` (adb serial or iOS UDID) of the device logs are streamed from
    @Published var selectedDeviceID: String? = nil {
        didSet {
            guard oldValue != selectedDeviceID else { return }
            routeSelection()
        }
    }

    /// Whether libimobiledevice is missing, so iPhones cannot be listed
    @Published private(set) var isMissingIOSTools = false

    let android: AndroidLogManager
    let ios: IOSLogManager

    /// The device last handed to a log manager, to know which one to stop on the next selection
    private var routedDevice: Device?

    /// Whether logs were already started automatically for a lone connected device
    private var hasAutoStarted = false

    init(android: AndroidLogManager, ios: IOSLogManager) {
        self.android = android
        self.ios = ios

        // Child processes outlive the app: without this, every quit leaves an `adb logcat` or
        // `idevicesyslog` running in the background. Posted synchronously on the main thread.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in
            // Safe when nothing runs: there is no process to terminate then
            android.stopLogcat()
            ios.stopLogcat()
        }
    }

    /// The selected device's full description
    var selectedDevice: Device? {
        connectedDevices.first { $0.id == selectedDeviceID }
    }

    /// Platform of the selected device; Android when nothing is selected (historical behaviour)
    var selectedPlatform: Device.Platform {
        selectedDevice?.platform ?? .android
    }

    /// The log manager of `platform`
    func logManager(for platform: Device.Platform) -> LogStreamManager {
        switch platform {
        case .android: return android
        case .ios: return ios
        }
    }

    // MARK: - Selection

    /// Hands the selected device to its platform's manager. Switching platforms stops the previous
    /// platform's stream and starts the new one if logs were being streamed.
    private func routeSelection() {
        let previous = routedDevice
        let device = selectedDevice
        routedDevice = device

        let isSwitchingPlatform = previous?.platform != device?.platform
        let wasRunning = previous.map { logManager(for: $0.platform).isLogcatRunning } ?? false
        if let previous, isSwitchingPlatform {
            logManager(for: previous.platform).stopLogcat()
        }

        guard let device else { return }
        // On the same platform, the manager restarts its own running stream on the new device
        switch device.platform {
        case .android: android.selectedDevice = device.id
        case .ios: ios.selectedDevice = device
        }

        if isSwitchingPlatform, wasRunning {
            logManager(for: device.platform).startLogcat()
        }
    }

    // MARK: - Devices

    /// Lists the Android and iOS devices plugged in. The tools run on a background queue
    /// (resolving iPhone names spawns one process per device); the result is applied on main.
    func refreshDevices() {
        let android = self.android

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let isMissingIOSTools = !IOSLogManager.isAvailable
            let devices = android.listDevices() + IOSLogManager.listDevices()

            DispatchQueue.main.async {
                self?.applyDevices(devices, isMissingIOSTools: isMissingIOSTools)
            }
        }
    }

    /// Publishes a fresh device list, keeping the current selection while it is still connected
    private func applyDevices(_ devices: [Device], isMissingIOSTools: Bool) {
        let previousID = selectedDeviceID
        connectedDevices = devices
        if self.isMissingIOSTools != isMissingIOSTools {
            self.isMissingIOSTools = isMissingIOSTools
        }

        if !devices.contains(where: { $0.id == previousID }) {
            selectedDeviceID = devices.first?.id
        }

        // A device change is already routed through `selectedDeviceID`. Otherwise hand over the
        // refreshed instance (an iPhone may now be reached over Wi-Fi) and refresh the app's PIDs.
        if selectedDeviceID == previousID, let device = selectedDevice {
            routeSelection()
            switch device.platform {
            case .android: android.refreshPackagePids()
            case .ios: ios.refreshBuildPids()
            }
        }

        // With a single device there is nothing to choose: start streaming right away.
        // Only once, so a manual Stop is not undone by a later device refresh.
        if devices.count == 1, let device = devices.first, !hasAutoStarted {
            let logs = logManager(for: device.platform)
            if !logs.isLogcatRunning {
                hasAutoStarted = true
                logs.startLogcat()
            }
        }
    }
}
