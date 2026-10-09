//
//  DeviceSelectorView.swift
//  LogCatAndroid
//
//  Created by Mikhail on 27/05/2025.
//

import SwiftUI

struct DeviceSelectorView: View {
    @ObservedObject var devices: DeviceManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if devices.connectedDevices.isEmpty {
                Text("No devices connected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Picker("Device", selection: $devices.selectedDeviceID) {
                    ForEach(devices.connectedDevices) { device in
                        Label(device.displayName, systemImage: device.platform.symbol)
                            .tag(device.id as String?)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                // Keep the popup flush left, in line with the other sidebar controls
                .frame(maxWidth: .infinity, alignment: .leading)

                if let device = devices.selectedDevice {
                    Label(device.platform.displayName, systemImage: device.platform.symbol)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help(device.id)
                }
            }

            if devices.isMissingIOSTools {
                Label("iPhones need libimobiledevice: \(IOSLogManager.installCommand)",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                devices.refreshDevices()
            } label: {
                Label("Refresh Devices", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
        }
    }
}
