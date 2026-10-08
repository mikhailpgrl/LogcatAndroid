//
//  DeviceSelectorView.swift
//  LogCatAndroid
//
//  Created by Mikhail on 27/05/2025.
//

import SwiftUI

struct DeviceSelectorView: View {
    @ObservedObject var adbManager: ADBManager
    /// Opens the setup screen, offered when a platform's tools are missing
    var onSetUpTools: () -> Void = {}

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

            if !adbManager.platformsMissingTools.isEmpty {
                Button(action: onSetUpTools) {
                    Label(missingToolsText, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
                .help("Open the setup screen to install them")
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

    /// e.g. "Android tools missing — Set Up…"
    private var missingToolsText: String {
        let platforms = adbManager.platformsMissingTools.map(\.displayName).joined(separator: " & ")
        return "\(platforms) tools missing — Set Up…"
    }
}
