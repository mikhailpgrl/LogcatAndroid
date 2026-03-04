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
                    ForEach(adbManager.connectedDevices, id: \.self) { device in
                        Text(device).tag(device as String?)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
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
