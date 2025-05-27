import SwiftUI

struct DeviceSelectorView: View {
    @ObservedObject var adbManager: ADBManager

    var body: some View {
        VStack(alignment: .leading) {
            Text("Connected Devices:")
                .font(.headline)
            if adbManager.connectedDevices.isEmpty {
                Text("No devices connected")
                    .foregroundColor(.secondary)
            } else {
                Picker("Select device", selection: $adbManager.selectedDevice) {
                    ForEach(adbManager.connectedDevices, id: \.self) { device in
                        Text(device).tag(device as String?)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 300)
            }
            Button("Refresh Devices") {
                adbManager.refreshDevices()
            }
            .padding(.top, 4)
        }
        .padding()
    }
}
