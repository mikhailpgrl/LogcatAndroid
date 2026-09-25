import Foundation

class ADBManager: ObservableObject {
    @Published var logEntries: [LogEntry] = []
    @Published var isLogcatRunning = false
    @Published var connectedDevices: [String] = []

    @Published var selectedDevice: String? = nil {
        didSet {
            guard oldValue != selectedDevice else { return }
            refreshPackagePids()
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
    private var entryIndex: Int = 0

    /// Pending entries accumulated on the background thread, flushed periodically
    private var pendingEntries: [LogEntry] = []
    private let pendingLock = NSLock()
    private var flushTimer: DispatchSourceTimer?

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

    /// Whether logcat was already started automatically for a lone connected device
    private var hasAutoStarted = false

    private static let selectedPackageKey = "selectedPackage"

    let adbPath: String = "/opt/homebrew/bin/adb"

    init() {
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

    func startLogcat() {
        guard FileManager.default.isExecutableFile(atPath: adbPath) else {
            print("❌ ADB not found at \(adbPath)")
            return
        }

        entryIndex = 0
        pendingLock.lock()
        pendingEntries.removeAll()
        pendingLock.unlock()

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

                                let currentIndex = self.entryIndex
                                self.entryIndex = currentIndex + 1
                                let entry = LogEntry.parse(line: line, index: currentIndex)

                                self.pendingLock.lock()
                                self.pendingEntries.append(entry)
                                self.pendingLock.unlock()
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

    func stopLogcat() {
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

    func clearLogs() {
        pendingLock.lock()
        pendingEntries.removeAll()
        pendingLock.unlock()
        DispatchQueue.main.async {
            self.logEntries.removeAll()
        }
    }

    // MARK: - Batched Flush

    private func startFlushTimer() {
        stopFlushTimer()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            self?.flushToMain()
        }
        timer.resume()
        flushTimer = timer
    }

    private func stopFlushTimer() {
        flushTimer?.cancel()
        flushTimer = nil
    }

    private func flushToMain() {
        pendingLock.lock()
        let batch = pendingEntries
        pendingEntries.removeAll()
        pendingLock.unlock()

        guard !batch.isEmpty else { return }

        DispatchQueue.main.async {
            for entry in batch {
                // The same event is often logged once per analytics backend, under a different
                // tag each time: fold those duplicates into a single entry carrying every tag.
                if let index = self.indexOfSameEvent(as: entry) {
                    self.logEntries[index].merge(entry)
                } else {
                    self.logEntries.append(entry)
                }
            }
            // Limit buffer to last 5000 entries
            if self.logEntries.count > 5000 {
                self.logEntries.removeFirst(self.logEntries.count - 5000)
            }
        }
    }

    /// Looks back through the most recent entries for the same event logged under another tag.
    /// Duplicates are emitted back to back, so a short window is enough.
    private func indexOfSameEvent(as entry: LogEntry) -> Int? {
        let window = 50
        let lowerBound = max(0, logEntries.count - window)
        for index in stride(from: logEntries.count - 1, through: lowerBound, by: -1)
        where logEntries[index].isSameEvent(as: entry) {
            return index
        }
        return nil
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
        guard FileManager.default.isExecutableFile(atPath: adbPath) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = (device.map { ["-s", $0] } ?? []) + arguments

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

    // MARK: - Devices

    func refreshDevices() {
        guard FileManager.default.isExecutableFile(atPath: adbPath) else {
            print("❌ ADB not found at \(adbPath)")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = ["devices"]

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let lines = output
                    .split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !$0.contains("List of devices") }

                let deviceIDs = lines.compactMap { line -> String? in
                    let parts = line.split(separator: "\t")
                    if parts.count >= 2 && parts[1] == "device" {
                        return String(parts[0])
                    }
                    return nil
                }

                DispatchQueue.main.async {
                    let previousDevice = self.selectedDevice
                    self.connectedDevices = deviceIDs
                    if !deviceIDs.contains(previousDevice ?? "") {
                        self.selectedDevice = deviceIDs.first
                    }
                    // A device change already refreshes the PIDs through `selectedDevice`
                    if self.selectedDevice == previousDevice {
                        self.refreshPackagePids()
                    }

                    // With a single device there is nothing to choose: start streaming right away.
                    // Only once, so a manual Stop is not undone by a later device refresh.
                    if deviceIDs.count == 1, !self.hasAutoStarted, !self.isLogcatRunning {
                        self.hasAutoStarted = true
                        self.startLogcat()
                    }
                }
            }
        } catch {
            print("❌ Failed to get devices: \(error)")
        }
    }
}
