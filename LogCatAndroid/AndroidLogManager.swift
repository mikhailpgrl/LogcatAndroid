import Foundation

/// Streams `adb logcat` from an Android device and keeps the analytics lines of the selected app,
/// told apart by the PIDs of its processes. iOS devices are handled by `IOSLogManager`.
final class AndroidLogManager: LogStreamManager {
    /// The adb serial of the device logs are streamed from, set by `DeviceManager`
    @Published var selectedDevice: String? = nil {
        didSet {
            guard oldValue != selectedDevice else { return }
            if isLogcatRunning {
                // The running stream targets the previous device
                stopLogcat()
                clearLogs()
                startLogcat()
            } else {
                refreshPackagePids()
            }
        }
    }

    /// The app package whose logs are displayed. `nil` means "all apps" (no package filtering).
    @Published var selectedPackage: AppPackage? {
        didSet { packageSelectionChanged(from: oldValue) }
    }

    /// PIDs currently matching `selectedPackage` on the selected device (empty when the app is not running)
    @Published var packagePids: [String] = []

    private var task: Process?
    private var pipe: Pipe?

    /// State shared with the background threads (reader + PID refresher), guarded by `stateLock`
    private struct FilterState {
        var package: AppPackage?
        var device: String?
        /// `nil` means no PID filtering; an empty set means "the app is not running"
        var pids: Set<String>?
        /// Bumped on every start/stop so a stale reader thread stops publishing entries
        var generation: Int = 0
    }

    private var filterState = FilterState()
    private let stateLock = NSLock()
    private var pidRefreshTimer: DispatchSourceTimer?

    private static let selectedPackageKey = "selectedPackage"

    /// Where adb is run from, also checked by the setup screen
    static let adbPath = "/opt/homebrew/bin/adb"

    var adbPath: String { Self.adbPath }

    override init() {
        super.init()
        let stored = UserDefaults.standard.string(forKey: Self.selectedPackageKey)
        selectedPackage = stored.flatMap(AppPackage.init(rawValue:)) ?? .photoPrint
        filterState.package = selectedPackage
    }

    func startADBServer() {
        guard FileManager.default.isExecutableFile(atPath: adbPath) else {
            print("❌ ADB not found at \(adbPath)")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = ["start-server"]

        do {
            try process.run()
            process.waitUntilExit()
            print("✅ ADB server started")
        } catch {
            print("❌ Failed to start adb server: \(error)")
        }
    }

    override func startLogcat() {
        guard FileManager.default.isExecutableFile(atPath: adbPath) else {
            print("❌ ADB not found at \(adbPath)")
            return
        }

        resetPendingEntries()

        // Resolve the PIDs of the selected package before reading, so the very first
        // lines are already filtered.
        let device = selectedDevice
        let package = selectedPackage
        let pids = package.map { fetchPids(for: $0, device: device) }

        stateLock.lock()
        filterState.device = device
        filterState.package = package
        filterState.pids = pids
        filterState.generation += 1
        let generation = filterState.generation
        stateLock.unlock()

        publishPackagePids(pids)

        if let package, let pids, pids.isEmpty {
            print("⚠️ \(package.packageName) is not running — no logs will match until it starts")
        }

        pipe = Pipe()
        task = Process()
        task?.executableURL = URL(fileURLWithPath: adbPath)
        if let device {
            task?.arguments = ["-s", device, "logcat"]
        } else {
            task?.arguments = ["logcat"]
        }

        task?.standardOutput = pipe
        task?.standardError = pipe

        guard let fileHandle = pipe?.fileHandleForReading else {
            print("❌ Failed to create pipe for adb output")
            return
        }

        startFlushTimer()
        startPidRefreshTimer()

        do {
            try task?.run()
            print("✅ Logcat started")
            DispatchQueue.main.async {
                self.isLogcatRunning = true
            }

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                let bufferSize = 8192
                var leftoverData = Data()

                while self.task?.isRunning == true, self.isCurrentGeneration(generation) {
                    autoreleasepool {
                        // PIDs are refreshed periodically, so re-read the filter on every chunk
                        let (activePids, activePackage) = self.currentFilter()

                        if let data = try? fileHandle.read(upToCount: bufferSize), !data.isEmpty {
                            leftoverData.append(data)

                            while let range = leftoverData.range(of: Data([0x0A])) {
                                let lineData = leftoverData.subdata(in: 0..<range.lowerBound)
                                leftoverData.removeSubrange(0...range.lowerBound)

                                guard let line = String(data: lineData, encoding: .utf8) else { continue }

                                // Only keep the analytics lines of the selected app
                                guard Self.shouldKeep(line: line, package: activePackage) else { continue }

                                // Only keep lines emitted by the selected package's process(es)
                                if let activePids {
                                    guard let pid = LogEntry.extractPid(from: line),
                                          activePids.contains(pid) else { continue }
                                }

                                self.enqueue(line: line)
                            }
                        }
                    }
                }

                // Flush remaining entries when logcat stops
                if self.isCurrentGeneration(generation) {
                    self.flushToMain()
                }
            }
        } catch {
            stopFlushTimer()
            stopPidRefreshTimer()
            DispatchQueue.main.async {
                self.isLogcatRunning = false
            }
            print("❌ Failed to run adb logcat: \(error)")
        }
    }

    override func stopLogcat() {
        task?.terminate()
        task = nil
        stopFlushTimer()
        stopPidRefreshTimer()
        flushToMain()
        stateLock.lock()
        filterState.generation += 1
        stateLock.unlock()
        DispatchQueue.main.async {
            self.isLogcatRunning = false
        }
        print("🛑 Logcat stopped")
    }

    // MARK: - Package Filtering

    /// Called on the main queue whenever the user picks another app
    private func packageSelectionChanged(from oldValue: AppPackage?) {
        guard oldValue != selectedPackage else { return }
        UserDefaults.standard.set(selectedPackage?.rawValue, forKey: Self.selectedPackageKey)

        if isLogcatRunning {
            // The buffered logs belong to the previous app: restart from a clean slate
            stopLogcat()
            clearLogs()
            startLogcat()
        } else {
            refreshPackagePids()
        }
    }

    /// Re-resolves the PIDs of the selected package. Must be called from the main queue.
    func refreshPackagePids() {
        let device = selectedDevice
        let package = selectedPackage

        stateLock.lock()
        filterState.device = device
        filterState.package = package
        stateLock.unlock()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.refreshPackagePidsFromState()
        }
    }

    /// Runs on a background queue: reads the current package/device, resolves PIDs, publishes them
    private func refreshPackagePidsFromState() {
        stateLock.lock()
        let package = filterState.package
        let device = filterState.device
        stateLock.unlock()

        // No PID filtering for "all apps"
        guard let package else {
            stateLock.lock()
            filterState.pids = nil
            stateLock.unlock()
            publishPackagePids(nil)
            return
        }

        let pids = fetchPids(for: package, device: device)

        stateLock.lock()
        // Only apply if the selection did not change while adb was running
        guard filterState.package == package, filterState.device == device else {
            stateLock.unlock()
            return
        }
        filterState.pids = pids
        stateLock.unlock()

        publishPackagePids(pids)
    }

    private func startPidRefreshTimer() {
        stopPidRefreshTimer()
        guard selectedPackage != nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            self?.refreshPackagePidsFromState()
        }
        timer.resume()
        pidRefreshTimer = timer
    }

    private func stopPidRefreshTimer() {
        pidRefreshTimer?.cancel()
        pidRefreshTimer = nil
    }

    private func isCurrentGeneration(_ generation: Int) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return filterState.generation == generation
    }

    private func currentFilter() -> (pids: Set<String>?, package: AppPackage?) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (filterState.pids, filterState.package)
    }

    /// Whether a raw logcat line should be displayed for `package`.
    /// With no package selected ("all apps"), a line is kept if it matches any known app's format.
    private static func shouldKeep(line: String, package: AppPackage?) -> Bool {
        guard let package else {
            return AppPackage.allCases.contains { $0.matches(line: line) }
        }
        return package.matches(line: line)
    }

    private func publishPackagePids(_ pids: Set<String>?) {
        let sorted = (pids ?? []).sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
        DispatchQueue.main.async {
            if self.packagePids != sorted {
                self.packagePids = sorted
            }
        }
    }

    /// Resolves the PIDs of every process belonging to `package`, across all its package
    /// identifiers (release and debug builds) and the `:suffix` child processes an app may spawn.
    private func fetchPids(for package: AppPackage, device: String?) -> Set<String> {
        // The process list is the most reliable source: unlike `pidof` it also matches
        // build variants and child processes.
        for arguments in [["shell", "ps", "-A", "-o", "PID,NAME"], ["shell", "ps", "-A"]] {
            guard let output = runADB(arguments, device: device) else { continue }
            var pids: Set<String> = []
            for name in package.packageNames {
                pids.formUnion(Self.pids(in: output, matching: name))
            }
            if !pids.isEmpty { return pids }
        }

        // Last resort on devices with an unusual `ps`: exact process names
        var pids: Set<String> = []
        for processName in package.processNames {
            guard let output = runADB(["shell", "pidof", processName], device: device) else { continue }
            pids.formUnion(
                output
                    .split(whereSeparator: { $0.isWhitespace })
                    .map(String.init)
                    .filter { Int($0) != nil }
            )
        }
        return pids
    }

    /// Extracts the PIDs whose process name is exactly `package` (or a `package:child` process)
    /// from a `ps` listing. Handles both `ps -A -o PID,NAME` and the legacy multi-column output.
    static func pids(in output: String, matching package: String) -> Set<String> {
        var pids: Set<String> = []

        for line in output.split(separator: "\n") {
            let columns = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard columns.count >= 2,
                  let pid = columns.first(where: { Int($0) != nil }),
                  let processName = columns.last else { continue }

            // Exact package name, or one of its `:remote` child processes.
            // Build variants (.debug) are listed explicitly in `AppPackage.packageNames`.
            if processName == package || processName.hasPrefix("\(package):") {
                pids.insert(pid)
            }
        }

        return pids
    }

    /// Runs a short-lived adb command and returns its stdout, or `nil` on failure
    private func runADB(_ arguments: [String], device: String?) -> String? {
        runTool(adbPath, (device.map { ["-s", $0] } ?? []) + arguments)
    }

    // MARK: - Devices

    /// Devices in the `device` state reported by `adb devices` (unauthorized/offline ones are skipped).
    /// Blocks while adb runs: call it off the main queue.
    func listDevices() -> [Device] {
        guard FileManager.default.isExecutableFile(atPath: adbPath) else {
            print("❌ ADB not found at \(adbPath)")
            return []
        }
        guard let output = runTool(adbPath, ["devices"]) else {
            print("❌ Failed to get adb devices")
            return []
        }

        return output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("List of devices") }
            .compactMap { line -> Device? in
                let parts = line.split(separator: "\t")
                guard parts.count >= 2, parts[1] == "device" else { return nil }
                let serial = String(parts[0])
                return Device(id: serial, name: serial, platform: .android)
            }
    }

    /// Runs a short-lived command and returns its stdout, or `nil` when it is missing or fails
    private func runTool(_ path: String, _ arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()

        do {
            try process.run()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
