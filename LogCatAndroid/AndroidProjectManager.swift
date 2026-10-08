//
//  AndroidProjectManager.swift
//  LogCatAndroid
//

import Foundation

/// A Gradle module that produces an Android application
struct AndroidModule: Identifiable, Hashable {
    /// Gradle project path, e.g. `:app` or `:apps:photoprint`
    let gradlePath: String

    var id: String { gradlePath }

    /// Name shown in the picker, without the leading colon
    var displayName: String { String(gradlePath.dropFirst()) }

    /// Directory relative to the repository root
    var relativeDirectory: String {
        gradlePath.split(separator: ":").joined(separator: "/")
    }
}

/// Connects the app to the git repository of an Android project: pick a branch,
/// build it with Gradle, then install and launch the APK on a device through adb.
final class AndroidProjectManager: ObservableObject {
    /// Step of the pipeline currently running, shown in the sidebar
    enum Phase: Equatable {
        case idle, cloning, fetching, checkingOut, building, installing, launching

        var label: String {
            switch self {
            case .idle: return ""
            case .cloning: return "Cloning…"
            case .fetching: return "Fetching…"
            case .checkingOut: return "Checking out…"
            case .building: return "Building…"
            case .installing: return "Installing…"
            case .launching: return "Launching…"
            }
        }
    }

    enum ProjectError: LocalizedError {
        case noProject
        case notAGitRepository(String)
        case uncommittedChanges
        case gradleWrapperMissing
        case noApplicationModule
        case apkNotFound(String)
        case aapt2NotFound
        case badgingFailed
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .noProject:
                return "No Android project selected"
            case .notAGitRepository(let path):
                return "\(path) is not a git repository"
            case .uncommittedChanges:
                return "The working tree has uncommitted changes. Commit or stash them before switching branch."
            case .gradleWrapperMissing:
                return "No gradlew script at the root of the project"
            case .noApplicationModule:
                return "No Android application module found in the project"
            case .apkNotFound(let directory):
                return "No APK found under \(directory)"
            case .aapt2NotFound:
                return "aapt2 not found in the Android SDK build-tools"
            case .badgingFailed:
                return "Could not read the package name from the APK"
            case .launchFailed(let package):
                return "Could not launch \(package)"
            }
        }
    }

    // MARK: - Published State

    /// Local checkout of the Android project
    @Published var projectPath: String? {
        didSet { UserDefaults.standard.set(projectPath, forKey: Keys.projectPath) }
    }

    /// Remote URL used for cloning, remembered for next time
    @Published var remoteURL: String {
        didSet { UserDefaults.standard.set(remoteURL, forKey: Keys.remoteURL) }
    }

    /// Local + remote branch names, without the `origin/` prefix
    @Published var branches: [String] = []

    /// The branch checked out on disk (`HEAD` when detached)
    @Published var currentBranch: String? = nil

    /// The branch picked in the UI; differs from `currentBranch` while a checkout runs
    @Published var selectedBranch: String? = nil

    /// Whether the working tree has uncommitted changes
    @Published var hasUncommittedChanges = false

    /// Application modules found in `settings.gradle`
    @Published var modules: [AndroidModule] = []

    @Published var selectedModule: AndroidModule? {
        didSet { UserDefaults.standard.set(selectedModule?.gradlePath, forKey: Keys.module) }
    }

    /// Build variant to assemble, e.g. `debug` or `stagingDebug`
    @Published var variant: String {
        didSet { UserDefaults.standard.set(variant, forKey: Keys.variant) }
    }

    /// Optional JAVA_HOME override; empty means auto-detect
    @Published var javaHomeOverride: String {
        didSet { UserDefaults.standard.set(javaHomeOverride, forKey: Keys.javaHome) }
    }

    /// Optional Android SDK root override; empty means auto-detect
    @Published var sdkRootOverride: String {
        didSet { UserDefaults.standard.set(sdkRootOverride, forKey: Keys.sdkRoot) }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var isBusy = false
    @Published private(set) var statusMessage = ""
    @Published private(set) var errorMessage: String? = nil

    /// Combined output of every tool run so far
    @Published private(set) var log = ""

    // MARK: - Private

    private enum Keys {
        static let projectPath = "androidProject.path"
        static let remoteURL = "androidProject.remoteURL"
        static let module = "androidProject.module"
        static let variant = "androidProject.variant"
        static let javaHome = "androidProject.javaHome"
        static let sdkRoot = "androidProject.sdkRoot"
    }

    private let gitPath = "/usr/bin/git"
    private let shell = ShellCommand()
    private var currentTask: Task<Void, Never>?
    private var hasLoaded = false

    init() {
        let defaults = UserDefaults.standard
        projectPath = defaults.string(forKey: Keys.projectPath)
        remoteURL = defaults.string(forKey: Keys.remoteURL) ?? ""
        variant = defaults.string(forKey: Keys.variant) ?? "debug"
        javaHomeOverride = defaults.string(forKey: Keys.javaHome) ?? ""
        sdkRootOverride = defaults.string(forKey: Keys.sdkRoot) ?? ""
    }

    private var projectURL: URL? {
        projectPath.map { URL(fileURLWithPath: $0) }
    }

    /// Folder name of the checkout, shown as the project name
    var projectName: String? {
        projectURL?.lastPathComponent
    }

    // MARK: - Loading

    /// Loads branches and modules of the remembered project the first time the UI appears
    @MainActor
    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard projectURL != nil else { return }
        await perform(phase: .fetching, success: "Ready") { [self] in
            try await reloadProjectState(fetch: false)
        }
    }

    /// Uses an existing local checkout
    @MainActor
    func openProject(at url: URL) async {
        let gitDirectory = url.appendingPathComponent(".git").path
        guard FileManager.default.fileExists(atPath: gitDirectory) else {
            errorMessage = ProjectError.notAGitRepository(url.path).localizedDescription
            statusMessage = errorMessage ?? ""
            return
        }
        projectPath = url.path
        hasLoaded = true
        await perform(phase: .fetching, success: "Ready") { [self] in
            try await reloadProjectState(fetch: true)
        }
    }

    /// Clones `remote` into `destinationParent/<repo name>` and opens it
    @MainActor
    func clone(remote: String, into destinationParent: URL) async {
        let trimmed = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        remoteURL = trimmed

        let repoName = Self.repositoryName(from: trimmed)
        let destination = destinationParent.appendingPathComponent(repoName)

        await perform(phase: .cloning, success: "Cloned \(repoName)") { [self] in
            try await shell.runChecked(gitPath, ["clone", "--progress", trimmed, destination.path],
                                       environment: environment, onOutput: appendLog)
            projectPath = destination.path
            hasLoaded = true
            try await reloadProjectState(fetch: false)
        }
    }

    /// Fetches from the remote and refreshes the branch list
    @MainActor
    func refresh() async {
        await perform(phase: .fetching, success: "Branches up to date") { [self] in
            try await reloadProjectState(fetch: true)
        }
    }

    /// Switches the working tree to `branch` and fast-forwards it to the remote
    @MainActor
    func checkout(_ branch: String) async {
        guard branch != currentBranch else { return }
        selectedBranch = branch

        await perform(phase: .checkingOut, success: "On \(branch)") { [self] in
            guard let root = projectURL else { throw ProjectError.noProject }

            try await refreshWorkingTreeStatus(root: root)
            if hasUncommittedChanges {
                throw ProjectError.uncommittedChanges
            }

            try await shell.runChecked(gitPath, ["checkout", branch], currentDirectory: root,
                                       environment: environment, onOutput: appendLog)

            // Bring the branch up to date; a non-fast-forward is not fatal
            let pull = try await shell.run(gitPath, ["pull", "--ff-only"], currentDirectory: root,
                                           environment: environment, onOutput: appendLog)
            if !pull.succeeded {
                appendLog("⚠️ Could not fast-forward \(branch), building the local revision")
            }

            try await reloadProjectState(fetch: false)
        }

        // Put the picker back on the real branch if the checkout failed
        if errorMessage != nil {
            selectedBranch = currentBranch
        }
    }

    // MARK: - Build & Run

    /// Builds the selected module and variant, installs the APK on `device` and launches it.
    /// Returns the launched package name, or `nil` when a step failed.
    @MainActor
    @discardableResult
    func buildAndRun(device: String, adbPath: String) async -> String? {
        var launchedPackage: String?

        await perform(phase: .building, success: "Running on device") { [self] in
            guard let root = projectURL else { throw ProjectError.noProject }
            guard let module = selectedModule else { throw ProjectError.noApplicationModule }

            // 1. Gradle build
            let gradlew = root.appendingPathComponent("gradlew")
            guard FileManager.default.fileExists(atPath: gradlew.path) else {
                throw ProjectError.gradleWrapperMissing
            }
            try Self.ensureExecutable(gradlew)

            let task = "\(module.gradlePath):assemble\(Self.capitalizingFirstLetter(variant))"
            appendLog("▶ ./gradlew \(task)")
            try await shell.runChecked(gradlew.path, [task, "--console=plain"], currentDirectory: root,
                                       environment: environment, onOutput: appendLog)
            try Task.checkCancellation()

            // 2. Locate the APK that was just produced
            let apkDirectory = root
                .appendingPathComponent(module.relativeDirectory)
                .appendingPathComponent("build/outputs/apk")
            guard let apk = Self.newestAPK(in: apkDirectory) else {
                throw ProjectError.apkNotFound(apkDirectory.path)
            }
            appendLog("📦 \(apk.path)")

            // 3. Read the package name and launcher activity from the APK
            let badging = try await readBadging(of: apk)
            appendLog("📱 \(badging.package)" + (badging.launchableActivity.map { " · \($0)" } ?? ""))

            // 4. Install
            setPhase(.installing)
            try await install(apk: apk, package: badging.package, device: device, adbPath: adbPath)
            try Task.checkCancellation()

            // 5. Launch
            setPhase(.launching)
            try await launch(package: badging.package, activity: badging.launchableActivity,
                             device: device, adbPath: adbPath)
            launchedPackage = badging.package
        }

        return launchedPackage
    }

    /// Stops the running step; the pipeline reports itself as cancelled
    func cancel() {
        currentTask?.cancel()
        shell.terminate()
    }

    @MainActor
    func clearLog() {
        log = ""
    }

    // MARK: - Pipeline Helpers

    /// Runs `work` as the single active operation, tracking phase, status and errors
    @MainActor
    private func perform(phase: Phase, success: String, _ work: @escaping @MainActor () async throws -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        setPhase(phase)

        let task = Task { @MainActor in
            do {
                try await work()
                statusMessage = success
            } catch is CancellationError {
                statusMessage = "Cancelled"
                appendLog("🛑 Cancelled")
            } catch {
                if Task.isCancelled {
                    statusMessage = "Cancelled"
                    appendLog("🛑 Cancelled")
                } else {
                    let message = error.localizedDescription
                    errorMessage = message
                    statusMessage = message
                    appendLog("❌ \(message)")
                }
            }
        }
        currentTask = task
        await task.value
        currentTask = nil

        setPhase(.idle)
        isBusy = false
    }

    @MainActor
    private func setPhase(_ newPhase: Phase) {
        phase = newPhase
        if newPhase != .idle {
            statusMessage = newPhase.label
        }
    }

    /// Appends a line to the log; safe to call from any thread
    private func appendLog(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else { return }
        Task { @MainActor in
            log += trimmed + "\n"
            // Keep the buffer bounded on very chatty builds
            if log.count > 400_000 {
                log = String(log.suffix(300_000))
            }
        }
    }

    // MARK: - Git

    /// Reloads branches, current branch, working tree status and modules
    @MainActor
    private func reloadProjectState(fetch: Bool) async throws {
        guard let root = projectURL else { throw ProjectError.noProject }

        if fetch {
            let result = try await shell.run(gitPath, ["fetch", "--prune", "--quiet"], currentDirectory: root,
                                             environment: environment, onOutput: appendLog)
            if !result.succeeded {
                appendLog("⚠️ Fetch failed, showing the branches known locally")
            }
        }

        let refs = try await shell.runChecked(
            gitPath, ["for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/remotes/origin"],
            currentDirectory: root, environment: environment
        )
        let head = try await shell.runChecked(gitPath, ["rev-parse", "--abbrev-ref", "HEAD"],
                                              currentDirectory: root, environment: environment)
        let current = head.trimmingCharacters(in: .whitespacesAndNewlines)

        var names = Self.branchNames(from: refs)
        // A detached HEAD or an unpushed branch still needs an entry in the picker
        if !current.isEmpty, !names.contains(current) {
            names.insert(current, at: 0)
        }
        branches = names
        currentBranch = current.isEmpty ? nil : current
        selectedBranch = currentBranch

        try await refreshWorkingTreeStatus(root: root)
        reloadModules(root: root)
    }

    @MainActor
    private func refreshWorkingTreeStatus(root: URL) async throws {
        let status = try await shell.runChecked(gitPath, ["status", "--porcelain", "--untracked-files=no"],
                                                currentDirectory: root, environment: environment)
        hasUncommittedChanges = !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Turns `git for-each-ref` output into unique branch names, remote prefix stripped
    static func branchNames(from output: String) -> [String] {
        var seen: Set<String> = []
        var names: [String] = []
        for rawLine in output.split(separator: "\n") {
            var name = rawLine.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name != "origin", name != "origin/HEAD" else { continue }
            if name.hasPrefix("origin/") {
                name = String(name.dropFirst("origin/".count))
            }
            if seen.insert(name).inserted {
                names.append(name)
            }
        }
        // Main branches first, the rest alphabetically
        let preferred = ["main", "master", "develop", "dev"]
        return names.sorted { lhs, rhs in
            let lhsRank = preferred.firstIndex(of: lhs) ?? preferred.count
            let rhsRank = preferred.firstIndex(of: rhs) ?? preferred.count
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    /// Derives the checkout folder name from a clone URL (`git@host:org/repo.git` → `repo`)
    static func repositoryName(from remote: String) -> String {
        var name = remote
        while name.hasSuffix("/") { name.removeLast() }
        if let slash = name.lastIndex(where: { $0 == "/" || $0 == ":" }) {
            name = String(name[name.index(after: slash)...])
        }
        if name.hasSuffix(".git") {
            name = String(name.dropLast(4))
        }
        return name.isEmpty ? "repository" : name
    }

    // MARK: - Gradle

    /// Finds the application modules declared in `settings.gradle(.kts)`
    @MainActor
    private func reloadModules(root: URL) {
        let found = Self.applicationModules(in: root)
        modules = found

        let remembered = UserDefaults.standard.string(forKey: Keys.module)
        if let selectedModule, found.contains(selectedModule) {
            return
        }
        selectedModule = found.first { $0.gradlePath == remembered } ?? found.first
    }

    static func applicationModules(in root: URL) -> [AndroidModule] {
        var settingsText = ""
        for name in ["settings.gradle.kts", "settings.gradle"] {
            if let text = try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) {
                settingsText = text
                break
            }
        }

        var modules: [AndroidModule] = []
        for path in includedProjectPaths(in: settingsText) {
            let module = AndroidModule(gradlePath: path)
            let directory = root.appendingPathComponent(module.relativeDirectory)
            guard isApplicationModule(at: directory) else { continue }
            modules.append(module)
        }

        // Projects without an explicit settings file, or with a single conventional module
        if modules.isEmpty, isApplicationModule(at: root.appendingPathComponent("app")) {
            modules.append(AndroidModule(gradlePath: ":app"))
        }
        return modules
    }

    /// Extracts every project path from `include(":a", ":b")` / `include ':a', ':b'` statements
    static func includedProjectPaths(in settings: String) -> [String] {
        let pattern = #"include\s*\(?\s*((?:\s*["'][^"']+["']\s*,?)+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let quoted = try? NSRegularExpression(pattern: #"["']([^"']+)["']"#)

        var paths: [String] = []
        let range = NSRange(settings.startIndex..., in: settings)
        for match in regex.matches(in: settings, range: range) {
            guard let groupRange = Range(match.range(at: 1), in: settings) else { continue }
            let group = String(settings[groupRange])
            for inner in quoted?.matches(in: group, range: NSRange(group.startIndex..., in: group)) ?? [] {
                guard let valueRange = Range(inner.range(at: 1), in: group) else { continue }
                var value = String(group[valueRange])
                if !value.hasPrefix(":") { value = ":" + value }
                if !paths.contains(value) { paths.append(value) }
            }
        }
        return paths
    }

    /// Whether the module's build script applies the Android application plugin
    private static func isApplicationModule(at directory: URL) -> Bool {
        for name in ["build.gradle.kts", "build.gradle"] {
            guard let text = try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8) else {
                continue
            }
            // Matches `com.android.application` and `alias(libs.plugins.android.application)`
            return text.contains("android.application") || text.contains("android-application")
        }
        return false
    }

    /// The most recently written APK under the module's outputs (the one assemble just produced)
    static func newestAPK(in directory: URL) -> URL? {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else {
            return nil
        }

        var newest: (url: URL, date: Date)?
        for case let url as URL in enumerator {
            guard url.pathExtension == "apk", !url.lastPathComponent.contains("unaligned") else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            let date = values?.contentModificationDate ?? .distantPast
            if let current = newest, date <= current.date { continue }
            newest = (url, date)
        }
        return newest?.url
    }

    private static func ensureExecutable(_ url: URL) throws {
        guard !FileManager.default.isExecutableFile(atPath: url.path) else { return }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    static func capitalizingFirstLetter(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    // MARK: - APK Inspection

    private struct Badging {
        let package: String
        let launchableActivity: String?
    }

    private func readBadging(of apk: URL) async throws -> Badging {
        guard let aapt2 = aapt2Path else { throw ProjectError.aapt2NotFound }
        let output = try await shell.runChecked(aapt2, ["dump", "badging", apk.path], environment: environment)
        guard let badging = Self.parseBadging(output) else { throw ProjectError.badgingFailed }
        return badging
    }

    private static func parseBadging(_ output: String) -> Badging? {
        guard let package = firstMatch(#"package: name='([^']+)'"#, in: output) else { return nil }
        let activity = firstMatch(#"launchable-activity: name='([^']+)'"#, in: output)
        return Badging(package: package, launchableActivity: activity)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    // MARK: - ADB

    private func install(apk: URL, package: String, device: String, adbPath: String) async throws {
        let arguments = ["-s", device, "install", "-r", "-t", "-d", apk.path]
        let result = try await shell.run(adbPath, arguments, environment: environment, onOutput: appendLog)
        if result.succeeded, !result.output.contains("Failure") { return }

        // A build signed with another key cannot update the installed app: replace it
        let incompatible = ["INSTALL_FAILED_UPDATE_INCOMPATIBLE", "INSTALL_FAILED_VERSION_DOWNGRADE",
                            "INSTALL_FAILED_ALREADY_EXISTS"]
        guard incompatible.contains(where: result.output.contains) else {
            throw ShellError.failed(command: "adb install", status: result.status, output: result.output)
        }

        appendLog("⚠️ Installed app is incompatible, uninstalling \(package) first")
        _ = try await shell.run(adbPath, ["-s", device, "uninstall", package],
                                environment: environment, onOutput: appendLog)
        try await shell.runChecked(adbPath, arguments, environment: environment, onOutput: appendLog)
    }

    private func launch(package: String, activity: String?, device: String, adbPath: String) async throws {
        if let activity {
            let component = "\(package)/\(activity)"
            let result = try await shell.run(adbPath, ["-s", device, "shell", "am", "start", "-n", component],
                                             environment: environment, onOutput: appendLog)
            if result.succeeded, !result.output.contains("Error") { return }
        }

        // No launcher activity in the badging: let the launcher intent resolve it
        let result = try await shell.run(
            adbPath, ["-s", device, "shell", "monkey", "-p", package, "-c", "android.intent.category.LAUNCHER", "1"],
            environment: environment, onOutput: appendLog
        )
        guard result.succeeded, !result.output.contains("No activities found") else {
            throw ProjectError.launchFailed(package)
        }
    }

    // MARK: - Toolchain Detection

    /// Environment handed to git, gradlew and adb. GUI apps start with a minimal environment,
    /// so the usual developer paths are added explicitly.
    var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let java = resolvedJavaHome
        let sdk = resolvedSDKRoot

        if let java {
            env["JAVA_HOME"] = java
        }
        if let sdk {
            env["ANDROID_HOME"] = sdk
            env["ANDROID_SDK_ROOT"] = sdk
        }

        var path: [String] = []
        if let java { path.append(java + "/bin") }
        path += ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/usr/local/bin", "/opt/homebrew/bin"]
        if let sdk { path.append(sdk + "/platform-tools") }
        if let existing = env["PATH"] {
            path += existing.split(separator: ":").map(String.init)
        }
        var seen: Set<String> = []
        env["PATH"] = path.filter { seen.insert($0).inserted }.joined(separator: ":")
        return env
    }

    /// JAVA_HOME to use: the override, the environment, Android Studio's bundled JDK, or an installed JDK
    var resolvedJavaHome: String? {
        let fileManager = FileManager.default
        let override = javaHomeOverride.trimmingCharacters(in: .whitespaces)
        if !override.isEmpty, fileManager.fileExists(atPath: override) {
            return override
        }
        if let fromEnvironment = ProcessInfo.processInfo.environment["JAVA_HOME"],
           fileManager.fileExists(atPath: fromEnvironment) {
            return fromEnvironment
        }

        let home = fileManager.homeDirectoryForCurrentUser.path
        var candidates = [
            "/Applications/Android Studio.app/Contents/jbr/Contents/Home",
            "\(home)/Applications/Android Studio.app/Contents/jbr/Contents/Home"
        ]
        // JetBrains Toolbox / Android Studio installs, newest first
        let jvmDirectory = "\(home)/Library/Java/JavaVirtualMachines"
        let installed = (try? fileManager.contentsOfDirectory(atPath: jvmDirectory)) ?? []
        candidates += installed
            .sorted { $0.localizedStandardCompare($1) == .orderedDescending }
            .map { "\(jvmDirectory)/\($0)/Contents/Home" }
        candidates.append("/Library/Java/JavaVirtualMachines")

        return candidates.first { fileManager.isExecutableFile(atPath: $0 + "/bin/java") }
    }

    /// Android SDK root: the override, the environment, the project's `local.properties`, or the default location
    var resolvedSDKRoot: String? {
        let fileManager = FileManager.default
        let override = sdkRootOverride.trimmingCharacters(in: .whitespaces)
        if !override.isEmpty, fileManager.fileExists(atPath: override) {
            return override
        }
        let env = ProcessInfo.processInfo.environment
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let value = env[key], fileManager.fileExists(atPath: value) {
                return value
            }
        }
        if let root = projectURL,
           let properties = try? String(contentsOf: root.appendingPathComponent("local.properties"), encoding: .utf8),
           let line = properties.split(separator: "\n").first(where: { $0.hasPrefix("sdk.dir=") }) {
            let value = String(line.dropFirst("sdk.dir=".count))
                .replacingOccurrences(of: "\\:", with: ":")
                .trimmingCharacters(in: .whitespaces)
            if fileManager.fileExists(atPath: value) {
                return value
            }
        }
        let defaultRoot = fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Android/sdk").path
        return fileManager.fileExists(atPath: defaultRoot) ? defaultRoot : nil
    }

    /// The newest `aapt2` in the SDK build-tools
    private var aapt2Path: String? {
        guard let sdk = resolvedSDKRoot else { return nil }
        let buildTools = sdk + "/build-tools"
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: buildTools)) ?? []
        let candidates = versions
            .sorted { $0.localizedStandardCompare($1) == .orderedDescending }
            .map { "\(buildTools)/\($0)/aapt2" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
