//
//  OnboardingView.swift
//  LogCatAndroid
//

import AppKit
import SwiftUI

/// Checks the command-line tools each platform needs and installs the missing ones through Homebrew.
/// Shown once, on first launch, then from the help button of the toolbar.
struct OnboardingView: View {
    @StateObject private var installer = ToolInstaller()
    @Environment(\.dismiss) private var dismiss

    /// Result of the last check, per platform. The checks read the file system, so they are
    /// re-run explicitly rather than on every render.
    @State private var installedPlatforms: Set<Device.Platform> = []
    @State private var hasHomebrew = false
    @State private var showLog = false

    private var allInstalled: Bool {
        ToolSetup.requirements.allSatisfy { installedPlatforms.contains($0.platform) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            VStack(spacing: 0) {
                homebrewRow
                ForEach(ToolSetup.requirements, id: \.platform) { requirement in
                    Divider()
                    toolRow(requirement)
                }
            }
            .background(.background.secondary)
            .clipShape(.rect(cornerRadius: 10))

            if !installer.log.isEmpty {
                DisclosureGroup("Installation log", isExpanded: $showLog) {
                    ScrollView {
                        Text(installer.log)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .defaultScrollAnchor(.bottom)
                    .frame(height: 140)
                }
                .font(.callout)
            }

            HStack {
                Button("Check Again", action: recheck)
                    .disabled(installer.isInstalling)
                Spacer()
                Button(allInstalled ? "Done" : "Continue") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(installer.isInstalling)
            }
        }
        .padding(24)
        .frame(width: 540)
        // Closing mid-install would leave brew running unseen
        .interactiveDismissDisabled(installer.isInstalling)
        .onAppear(perform: recheck)
        .onChange(of: installer.state) {
            recheck()
        }
        // Homebrew may have been installed in Terminal meanwhile
        .task {
            for await _ in NotificationCenter.default.notifications(named: NSApplication.didBecomeActiveNotification) {
                recheck()
            }
        }
    }

    private func recheck() {
        hasHomebrew = ToolSetup.brewPath != nil
        installedPlatforms = Set(ToolSetup.requirements.filter { $0.isAvailable() }.map(\.platform))
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text("Set Up LogCat")
                    .font(.title2.weight(.semibold))
                Text(allInstalled
                     ? "Everything is installed: plug in a device to start streaming its logs."
                     : "LogCat reads device logs through command-line tools. Install the ones you need below.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var homebrewRow: some View {
        SetupRow(
            symbol: "mug",
            title: "Homebrew",
            detail: hasHomebrew
                ? "Installs and updates the tools below."
                : "Needed to install the tools below. Its installer asks for your password, so it runs in Terminal.",
            command: ToolSetup.homebrewInstallCommand
        ) {
            if hasHomebrew {
                InstalledBadge()
            } else {
                Link("brew.sh", destination: ToolSetup.homebrewURL)
            }
        }
    }

    private func toolRow(_ requirement: ToolRequirement) -> some View {
        let platform = requirement.platform
        let isInstalled = installedPlatforms.contains(platform)

        return SetupRow(
            symbol: platform.symbol,
            title: "\(platform.displayName) · \(requirement.toolName)",
            detail: "Streams logs from \(platform.displayName) devices.",
            command: requirement.installCommand
        ) {
            if isInstalled {
                InstalledBadge()
            } else if installer.state == .installing(platform) {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Installing…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 8) {
                    if installer.state == .failed(platform) {
                        Label("Failed", systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .help("See the installation log")
                    }
                    Button(installer.state == .failed(platform) ? "Retry" : "Install") {
                        showLog = true
                        installer.install(requirement)
                    }
                    .disabled(!hasHomebrew || installer.isInstalling)
                }
            }
        }
    }
}

// MARK: - Components

/// A line of the setup checklist: what the tool is for, and its status or install action
private struct SetupRow<Accessory: View>: View {
    let symbol: String
    let title: String
    let detail: String
    /// The command behind the install button, for those who prefer a terminal
    var command: String? = nil
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let command {
                    HStack(spacing: 4) {
                        Text(command)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(command)
                        CopyCommandButton(command: command)
                    }
                }
            }

            Spacer(minLength: 12)

            accessory
        }
        .padding(12)
    }
}

/// Copies a command to the clipboard, showing a checkmark for a moment as confirmation
private struct CopyCommandButton: View {
    let command: String
    @State private var didCopy = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
            didCopy = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.5))
                didCopy = false
            }
        } label: {
            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                .font(.caption2)
                .foregroundStyle(didCopy ? Color.green : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderless)
        .help(didCopy ? "Copied" : "Copy to clipboard")
    }
}

private struct InstalledBadge: View {
    var body: some View {
        Label("Installed", systemImage: "checkmark.circle.fill")
            .font(.callout)
            .foregroundStyle(.green)
    }
}

#Preview {
    OnboardingView()
}
