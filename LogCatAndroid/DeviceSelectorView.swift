//
//  DeviceSelectorView.swift
//  LogCatAndroid
//
//  Created by Mikhail on 27/05/2025.
//

import SwiftUI

struct DeviceSelectorView: View {
    @ObservedObject var adbManager: ADBManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if adbManager.connectedDevices.isEmpty {
                Text("No devices connected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Picker("Device", selection: $adbManager.selectedDevice) {
                    ForEach(adbManager.connectedDevices) { device in
                        Label(device.name, systemImage: device.platform.symbol)
                            .tag(device.id as String?)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                // Keep the popup flush left, in line with the other sidebar controls
                .frame(maxWidth: .infinity, alignment: .leading)

                if let device = adbManager.selectedDeviceInfo {
                    Label(device.platform.displayName, systemImage: device.platform.symbol)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help(device.id)
                }
            }

            if let message = adbManager.toolMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                adbManager.refreshDevices()
            } label: {
                Label("Refresh Devices", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
        }
    }
}
