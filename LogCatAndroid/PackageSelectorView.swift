//
//  PackageSelectorView.swift
//  LogCatAndroid
//

import SwiftUI

struct PackageSelectorView: View {
    @ObservedObject var adbManager: ADBManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // A menu rather than a plain picker, so the closed control reads "Picta · Int"
            // while the items, grouped by app, carry the bundle identifiers
            Menu {
                Picker("App", selection: $adbManager.selectedBuild) {
                    Text("All apps").tag(nil as AppBuild?)
                    ForEach(AppBuild.appGroups(for: adbManager.currentPlatform), id: \.appName) { group in
                        Section(group.appName) {
                            ForEach(group.builds) { build in
                                Text(build.menuLabel).tag(build as AppBuild?)
                            }
                        }
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Text(adbManager.selectedBuild?.shortLabel ?? "All apps")
            }
            .fixedSize()
            // Flush left like the device picker above
            .frame(maxWidth: .infinity, alignment: .leading)

            Picker("Capture", selection: $adbManager.captureMode) {
                ForEach(CaptureMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            if let build = adbManager.selectedBuild {
                Text(build.id)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    Circle()
                        .fill(adbManager.buildPids.isEmpty ? Color.orange : Color.green)
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
        let pids = adbManager.buildPids
        guard !pids.isEmpty else { return "App not running" }
        return pids.count == 1
            ? "PID \(pids[0])"
            : "PIDs \(pids.joined(separator: ", "))"
    }
}
