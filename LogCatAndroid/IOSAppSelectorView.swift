//
//  IOSAppSelectorView.swift
//  LogCatAndroid
//

import SwiftUI

/// The iOS app picker: one entry per build (Prod / Int), grouped by app.
/// Android apps are picked in `PackageSelectorView`.
struct IOSAppSelectorView: View {
    @ObservedObject var iosLogs: IOSLogManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // A menu rather than a plain picker, so the closed control reads "Picta · Int"
            // while the items, grouped by app, carry the bundle identifiers
            Menu {
                Picker("App", selection: $iosLogs.selectedBuild) {
                    Text("All apps").tag(nil as IOSAppBuild?)
                    ForEach(IOSAppBuild.appGroups, id: \.appName) { group in
                        Section(group.appName) {
                            ForEach(group.builds) { build in
                                Text(build.menuLabel).tag(build as IOSAppBuild?)
                            }
                        }
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Text(iosLogs.selectedBuild?.shortLabel ?? "All apps")
            }
            .fixedSize()
            // Flush left like the device picker above
            .frame(maxWidth: .infinity, alignment: .leading)

            if let build = iosLogs.selectedBuild {
                Text(build.id)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    Circle()
                        .fill(iosLogs.buildPids.isEmpty ? Color.orange : Color.green)
                        .frame(width: 6, height: 6)
                    Text(statusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            // The builds of an app share their process: events of the build not selected are captured
            // but hidden. Say so, otherwise using Int while Prod is selected shows an empty list.
            let hiddenCount = iosLogs.hiddenEntries.count
            if hiddenCount > 0 {
                Label("\(hiddenCount) event\(hiddenCount == 1 ? "" : "s") from another build hidden",
                      systemImage: "eye.slash")
                    .font(.caption2)
                    .foregroundStyle(.orange)

                if let owner = iosLogs.buildOfHiddenEntries {
                    Button("Show \(owner.shortLabel)") {
                        iosLogs.selectedBuild = owner
                    }
                    .controlSize(.small)
                }
            }

            if let message = iosLogs.toolMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusText: String {
        let pids = iosLogs.buildPids
        guard !pids.isEmpty else { return "App not running" }
        return pids.count == 1
            ? "PID \(pids[0])"
            : "PIDs \(pids.joined(separator: ", "))"
    }
}
