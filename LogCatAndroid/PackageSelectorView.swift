//
//  PackageSelectorView.swift
//  LogCatAndroid
//

import SwiftUI

struct PackageSelectorView: View {
    @ObservedObject var adbManager: ADBManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("App", selection: $adbManager.selectedPackage) {
                Text("All apps").tag(nil as AppPackage?)
                ForEach(AppPackage.allCases) { package in
                    Text(package.displayName).tag(package as AppPackage?)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            // Flush left like the device picker above
            .frame(maxWidth: .infinity, alignment: .leading)

            if let package = adbManager.selectedPackage {
                Text("\(package.packageName) (+ debug)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    Circle()
                        .fill(adbManager.packagePids.isEmpty ? Color.orange : Color.green)
                        .frame(width: 6, height: 6)
                    Text(statusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }

    private var statusText: String {
        let pids = adbManager.packagePids
        guard !pids.isEmpty else { return "App not running" }
        return pids.count == 1
            ? "PID \(pids[0])"
            : "PIDs \(pids.joined(separator: ", "))"
    }
}
