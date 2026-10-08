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
                        Label(device.displayName, systemImage: device.platform.symbol)
                            .tag(device as Device?)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                // Keep the popup flush left, in line with the other sidebar controls
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Platforms that cannot be listed, with what to install
            ForEach(adbManager.missingTools, id: \.self) { hint in
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
