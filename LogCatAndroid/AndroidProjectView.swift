//
//  AndroidProjectView.swift
//  LogCatAndroid
//

import SwiftUI

/// Sidebar section: the Android project's branch, module and variant, plus a Build & Run button
/// that assembles the app with Gradle and launches it on the selected device.
struct AndroidProjectView: View {
    @ObservedObject var project: AndroidProjectManager
    @ObservedObject var adbManager: AndroidLogManager
    /// Called with the package name once the app is running on the device
    var onLaunched: ((String) -> Void)? = nil

    @Environment(\.appTheme) private var theme
    @State private var showSetup = false
    @State private var showLog = false

    /// Picker binding: choosing a branch checks it out right away
    private var branchSelection: Binding<String?> {
        Binding(
            get: { project.selectedBranch },
            set: { newValue in
                guard let newValue else { return }
                Task { await project.checkout(newValue) }
            }
        )
    }

    private func buildAndRun() {
        guard let device = adbManager.selectedDevice else { return }
        Task {
            if let package = await project.buildAndRun(device: device, adbPath: adbManager.adbPath) {
                onLaunched?(package)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if project.projectPath == nil {
                Text("Connect a git repository to build and run its app.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    showSetup = true
                } label: {
                    Label("Open or Clone Project…", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
            } else {
                projectHeader
                branchRow
                moduleRow
                actionButton
                statusRow
            }
        }
        .task {
            await project.loadIfNeeded()
        }
        .sheet(isPresented: $showSetup) {
            AndroidProjectSetupView(project: project)
        }
        .sheet(isPresented: $showLog) {
            BuildLogView(project: project)
        }
    }

    /// Project folder name with a button to change it
    private var projectHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(project.projectName ?? "")
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(project.projectPath ?? "")
            Spacer()
            Button {
                showSetup = true
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Change project or tool paths")
        }
    }

    /// Branch picker with a fetch button
    private var branchRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Picker("Branch", selection: branchSelection) {
                    ForEach(project.branches, id: \.self) { branch in
                        Text(branch).tag(branch as String?)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(project.isBusy || project.branches.isEmpty)

                Button {
                    Task { await project.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(project.isBusy)
                .help("Fetch branches from the remote")
            }

            if project.hasUncommittedChanges {
                Label("Uncommitted changes", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help("Switching branch is blocked until the working tree is clean")
            }
        }
    }

    /// Application module picker and build variant field
    private var moduleRow: some View {
        HStack(spacing: 6) {
            if project.modules.count > 1 {
                Picker("Module", selection: $project.selectedModule) {
                    ForEach(project.modules) { module in
                        Text(module.displayName).tag(module as AndroidModule?)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .disabled(project.isBusy)
            } else {
                Text(project.selectedModule?.displayName ?? "no app module")
                    .font(.caption)
                    .foregroundStyle(project.selectedModule == nil ? .orange : .secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            TextField("variant", text: $project.variant)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .frame(width: 100)
                .disabled(project.isBusy)
                .help("Build variant, e.g. debug or stagingDebug")
        }
    }

    /// Build & Run while idle, Cancel while a step is running
    @ViewBuilder
    private var actionButton: some View {
        if project.isBusy {
            Button(role: .cancel) {
                project.cancel()
            } label: {
                Label("Cancel", systemImage: "xmark")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.regular)
        } else {
            Button {
                buildAndRun()
            } label: {
                Label("Build & Run", systemImage: "hammer.fill")
                    .frame(maxWidth: .infinity)
            }
            .glassButtons()
            .controlSize(.regular)
            .disabled(adbManager.selectedDevice == nil || project.selectedModule == nil)
            .help(adbManager.selectedDevice == nil
                  ? "Connect an Android device first"
                  : "Build the selected variant, install it and launch it on the device")
        }
    }

    /// Current step or last result, with a link to the full log
    private var statusRow: some View {
        HStack(alignment: .top, spacing: 6) {
            if project.isBusy {
                ProgressView()
                    .controlSize(.mini)
            } else if project.errorMessage != nil {
                Image(systemName: "xmark.octagon.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
            } else if !project.statusMessage.isEmpty {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }

            Text(project.statusMessage)
                .font(.caption2)
                .foregroundStyle(project.errorMessage == nil ? Color.secondary : Color.red)
                .lineLimit(2)
                .help(project.statusMessage)

            Spacer(minLength: 0)

            if !project.log.isEmpty {
                Button("Log") {
                    showLog = true
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(theme.accent)
                .help("Show the git, Gradle and adb output")
            }
        }
    }
}

// MARK: - Project Setup Sheet

/// Lets the user pick a local checkout or clone a remote repository, and override tool paths
struct AndroidProjectSetupView: View {
    @ObservedObject var project: AndroidProjectManager
    @Environment(\.dismiss) private var dismiss

    @State private var remoteURL = ""
    @State private var cloneDestination: URL? = nil
    @State private var showAdvanced = false

    /// Where a clone lands when no folder was picked
    private var defaultCloneDestination: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer")
    }

    private var cloneParent: URL { cloneDestination ?? defaultCloneDestination }

    private var canClone: Bool {
        !remoteURL.trimmingCharacters(in: .whitespaces).isEmpty && !project.isBusy
    }

    /// Opens a folder chooser and returns the picked directory
    private func chooseFolder(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = prompt
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func openExistingProject() {
        guard let url = chooseFolder(prompt: "Open") else { return }
        Task {
            await project.openProject(at: url)
            if project.errorMessage == nil {
                dismiss()
            }
        }
    }

    private func clone() {
        let parent = cloneParent
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        Task {
            await project.clone(remote: remoteURL, into: parent)
            if project.errorMessage == nil {
                dismiss()
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Android Project")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(project.isBusy)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    localProjectSection
                    cloneSection
                    toolsSection

                    if project.isBusy || project.errorMessage != nil {
                        HStack(spacing: 8) {
                            if project.isBusy {
                                ProgressView().controlSize(.small)
                            }
                            Text(project.statusMessage)
                                .font(.caption)
                                .foregroundStyle(project.errorMessage == nil ? Color.secondary : Color.red)
                                .lineLimit(3)
                        }
                    }
                }
                .padding()
            }
        }
        .frame(width: 520, height: 520)
        .onAppear {
            remoteURL = project.remoteURL
        }
    }

    private var localProjectSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Local Checkout", systemImage: "folder")
                .font(.headline)

            HStack(spacing: 8) {
                Text(project.projectPath ?? "No project selected")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(project.projectPath == nil ? .tertiary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(.background.secondary)
                    .clipShape(.rect(cornerRadius: 6))

                Button("Choose…") {
                    openExistingProject()
                }
                .disabled(project.isBusy)
            }

            Text("Pick the folder of an Android project that is already cloned.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var cloneSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Clone Repository", systemImage: "arrow.down.circle")
                .font(.headline)

            TextField("git@github.com:org/android-app.git", text: $remoteURL)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .disabled(project.isBusy)

            HStack(spacing: 8) {
                Text("Into")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(cloneParent.path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Change…") {
                    if let url = chooseFolder(prompt: "Select") {
                        cloneDestination = url
                    }
                }
                .controlSize(.small)
                .disabled(project.isBusy)
            }

            Button {
                clone()
            } label: {
                Label("Clone", systemImage: "arrow.down.to.line")
                    .frame(maxWidth: .infinity)
            }
            .disabled(!canClone)

            Text("Clones into a folder named after the repository, using your git credentials and SSH keys.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var toolsSection: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: 12) {
                ToolPathField(
                    title: "JAVA_HOME",
                    placeholder: project.resolvedJavaHome ?? "Not found",
                    text: $project.javaHomeOverride
                )
                ToolPathField(
                    title: "Android SDK",
                    placeholder: project.resolvedSDKRoot ?? "Not found",
                    text: $project.sdkRootOverride
                )
                Text("Leave empty to auto-detect (Android Studio's JDK, ~/Library/Android/sdk). The detected value is shown as placeholder.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.top, 8)
        } label: {
            Label("Build Tools", systemImage: "wrench.adjustable")
                .font(.headline)
        }
    }
}

/// Labeled path text field used for the tool overrides
private struct ToolPathField: View {
    let title: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.caption, design: .monospaced))
        }
    }
}

// MARK: - Build Log Sheet

/// Scrollable output of git, Gradle and adb, following the tail while a step runs
struct BuildLogView: View {
    @ObservedObject var project: AndroidProjectManager
    @Environment(\.dismiss) private var dismiss

    private let bottomAnchor = "bottom"

    private func copyLog() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(project.log, forType: .string)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Build Log")
                    .font(.title3.weight(.semibold))
                if project.isBusy {
                    ProgressView().controlSize(.small)
                    Text(project.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") {
                    copyLog()
                }
                Button("Clear", systemImage: "trash") {
                    project.clearLog()
                }
                .disabled(project.isBusy)
                if project.isBusy {
                    Button("Cancel", role: .cancel) {
                        project.cancel()
                    }
                }
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .controlSize(.small)
            .padding()

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(project.log)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                        Color.clear
                            .frame(height: 1)
                            .id(bottomAnchor)
                    }
                }
                .background(.background.secondary)
                .onAppear {
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
                .onChange(of: project.log.count) {
                    proxy.scrollTo(bottomAnchor, anchor: .bottom)
                }
            }
        }
        .frame(minWidth: 700, idealWidth: 800, minHeight: 400, idealHeight: 500)
    }
}
