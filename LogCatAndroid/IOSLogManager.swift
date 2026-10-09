//
//  IOSLogManager.swift
//  LogCatAndroid
//

import Foundation

/// Streams the analytics logs of the Pictarine iOS apps through libimobiledevice's `idevicesyslog`,
/// over USB or Wi-Fi. Wi-Fi devices must be paired with this Mac and have "Show this iPhone when
/// on Wi-Fi" enabled. Android devices are handled by `AndroidLogManager`.
///
/// Unlike logcat, the stream is narrowed down on the device side by process name (`-p`) and
/// analytics marker (`-m`). The builds of an app share their process, so the selected build's
/// entries are told apart by PID at display time (see `attributedPids`).
final class IOSLogManager: LogStreamManager {
    /// The iPhone logs are streamed from, set by `DeviceManager`
    @Published var selectedDevice: Device? = nil {
        didSet {
            // A refreshed instance of the same device (possibly renamed) is still the same selection,
            // unless it is now reached another way (USB ↔ Wi-Fi): the stream must be restarted then
            guard oldValue?.id != selectedDevice?.id || oldValue?.isWireless != selectedDevice?.isWireless
            else { return }
            toolMessage = nil
            if isLogcatRunning, selectedDevice != nil {
                // The buffered logs come from the previous device: restart from a clean slate
                stopLogcat()
                clearLogs()
                startLogcat()
            } else {
                refreshBuildPids()
            }
        }
    }

    /// The build whose logs are displayed. `nil` means "all apps".
    @Published var selectedBuild: IOSAppBuild? {
        didSet { buildSelectionChanged(from: oldValue) }
    }

    /// PIDs currently running `selectedBuild` on the selected device (empty when it is not running)
    @Published private(set) var buildPids: [String] = []

    /// Every PID attributed to `selectedBuild` during the current stream. The builds of an app share
    /// their process, so the stream carries them all, and a PID is only attributed a moment after
    /// the app starts: filtering the display rather than the capture keeps the first events of a
    /// freshly launched build. `nil` when every captured entry belongs to the selection.
    @Published private(set) var attributedPids: Set<String>?

    /// User-facing problem with the iOS tools (e.g. libimobiledevice not installed)
    @Published var toolMessage: String? = nil

    /// The command installing the tools this manager relies on
    static let installCommand = "brew install libimobiledevice"

    private var task: Process?

    /// State shared with the background threads (reader + PID refresher), guarded by `stateLock`
    private struct FilterState {
        var build: IOSAppBuild?
        var device: Device?
        /// Bumped on every start/stop so a stale reader thread stops publishing entries
        var generation: Int = 0
    }

    private var filterState = FilterState()
    private let stateLock = NSLock()
    private var pidRefreshTimer: DispatchSourceTimer?

    /// Tells the builds of an app apart, as they share their process name
    private let attribution = ProcessAttribution()

    private static let selectedBuildKey = "selectedBuild.ios"

    override init() {
        super.init()
        selectedBuild = UserDefaults.standard.string(forKey: Self.selectedBuildKey)
            .flatMap(IOSAppBuild.build(withID:))
        filterState.build = selectedBuild
    }

    override func startLogcat() {
        guard let device = selectedDevice else {
            print("❌ No iOS device selected")
            return
        }
        guard let syslogPath = IOSTool.locate("idevicesyslog") else {
            toolMessage = "idevicesyslog not found. Install libimobiledevice: \(Self.installCommand)"
            print("❌ idevicesyslog not found — \(Self.installCommand)")
            return
        }
        toolMessage = nil

        resetPendingEntries()

        // Resolve the PIDs of the selected build before reading, so its first events are attributed
        let build = selectedBuild
        let pids = build.map { runningPids(for: $0, device: device) }
        attributedPids = build == nil ? nil : (pids ?? [])

        stateLock.lock()
        filterState.device = device
        filterState.build = build
        filterState.generation += 1
        let generation = filterState.generation
        stateLock.unlock()

        publishBuildPids(pids)

        if let build, let pids, pids.isEmpty {
            print("⚠️ \(build.id) is not running — its events will show up once it starts")
        }

        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: syslogPath)
        process.arguments = Self.syslogArguments(device: device, build: build)
        process.standardOutput = pipe
        process.standardError = pipe
        task = process

        startFlushTimer()
        startPidRefreshTimer()

        do {
            try process.run()
            print("✅ idevicesyslog started")
            DispatchQueue.main.async {
                self.isLogcatRunning = true
            }

            let fileHandle = pipe.fileHandleForReading
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                var leftoverData = Data()
                var reachedEnd = false

                while !reachedEnd, process.isRunning, self.isCurrentGeneration(generation) {
                    autoreleasepool {
                        // `availableData` returns as soon as anything was written, whereas `read(upToCount:)`
                        // waits for the full count: the filtered stream is sparse and would lag behind.
                        let data = fileHandle.availableData
                        // An empty read is the end of the stream: the tool exited
                        reachedEnd = data.isEmpty
                        leftoverData.append(data)

                        while let range = leftoverData.range(of: Data([0x0A])) {
                            let lineData = leftoverData.subdata(in: 0..<range.lowerBound)
                            leftoverData.removeSubrange(0...range.lowerBound)

                            guard let line = String(data: lineData, encoding: .utf8),
                                  Self.shouldKeep(line: line, build: build) else { continue }

                            self.enqueue(line: line)
                        }
                    }
                }

                // Flush remaining entries when the stream stops
                if self.isCurrentGeneration(generation) {
                    self.flushToMain()
                }
            }
        } catch {
            task = nil
            stopFlushTimer()
            stopPidRefreshTimer()
            DispatchQueue.main.async {
                self.isLogcatRunning = false
            }
            print("❌ Failed to run idevicesyslog: \(error)")
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
        print("🛑 idevicesyslog stopped")
    }

    // MARK: - Stream Filtering

    /// Arguments for `idevicesyslog`. The whole system log (~1000 lines/s) still comes from the
    /// device, but `idevicesyslog` filters it before it reaches our pipe. Process names survive app
    /// relaunches, unlike PIDs; the other builds sharing the process come along and are told apart by PID.
    static func syslogArguments(device: Device, build: IOSAppBuild?) -> [String] {
        var processNames: [String] = []
        for name in (build.map { [$0] } ?? IOSAppBuild.all).map(\.processName)
        where !processNames.contains(name) {
            processNames.append(name)
        }
        return connectionArguments(for: device)
            + ["--no-colors", "-p", processNames.joined(separator: "|"), "-m", IOSAppBuild.analyticsMarker]
    }

    /// Whether a raw syslog line should be captured for `build`.
    /// With no build selected ("all apps"), a line is kept if it is an analytics event of any known app.
    static func shouldKeep(line: String, build: IOSAppBuild?) -> Bool {
        (build.map { [$0] } ?? IOSAppBuild.all).contains { $0.isAnalyticsLine(line) }
    }

    /// The libimobiledevice arguments targeting `device`: without `-n` only USB devices are looked up
    private static func connectionArguments(for device: Device) -> [String] {
        (device.isWireless ? ["-n"] : []) + ["-u", device.id]
    }

    // MARK: - Build Attribution

    /// Captured entries hidden from the display because another build of the app emitted them
    /// (e.g. Prod is selected while Int is the one being used: both run as the same process)
    var hiddenEntries: [LogEntry] {
        guard let attributedPids else { return [] }
        return logEntries.filter { !attributedPids.contains($0.pid) }
    }

    /// The build that emitted the hidden entries, to offer switching to it: told by `devicectl` when it
    /// attributed their process, otherwise the selection's sibling when its app has only two builds
    var buildOfHiddenEntries: IOSAppBuild? {
        guard let build = selectedBuild, let device = selectedDevice,
              let pid = hiddenEntries.last?.pid else { return nil }
        let siblings = IOSAppBuild.all.filter { $0.processName == build.processName && $0 != build }
        if let bundleID = attribution.cachedBundleIdentifier(of: pid, on: device),
           let owner = siblings.first(where: { $0.id == bundleID }) {
            return owner
        }
        return siblings.count == 1 ? siblings[0] : nil
    }

    /// Called on the main queue whenever the user picks another build
    private func buildSelectionChanged(from oldValue: IOSAppBuild?) {
        guard oldValue != selectedBuild else { return }
        UserDefaults.standard.set(selectedBuild?.id, forKey: Self.selectedBuildKey)

        if isLogcatRunning, let oldValue, let selectedBuild, oldValue.processName == selectedBuild.processName {
            // Another build of the same app (Prod ↔ Int): the stream already carries its events,
            // only the attribution changes. Keep the buffer so the hidden entries show up right away.
            attributedPids = []
            refreshBuildPids()
        } else if isLogcatRunning {
            // The buffered logs belong to the previous app: restart from a clean slate
            stopLogcat()
            clearLogs()
            startLogcat()
        } else {
            refreshBuildPids()
        }
    }

    /// Re-resolves the PIDs of the selected build. Must be called from the main queue.
    func refreshBuildPids() {
        stateLock.lock()
        filterState.device = selectedDevice
        filterState.build = selectedBuild
        stateLock.unlock()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.refreshBuildPidsFromState()
        }
    }

    /// Runs on a background queue: reads the current build/device, resolves PIDs, publishes them
    private func refreshBuildPidsFromState() {
        stateLock.lock()
        let build = filterState.build
        let device = filterState.device
        stateLock.unlock()

        guard let build, let device else {
            publishBuildPids(nil)
            return
        }

        let pids = runningPids(for: build, device: device)

        stateLock.lock()
        // Only apply if the selection did not change while the tools were running
        guard filterState.build == build, filterState.device == device else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        publishBuildPids(pids)
        DispatchQueue.main.async {
            // Only while a stream attributes PIDs: stopped, the display keeps what was captured.
            // A result for a build that was deselected meanwhile must not be attributed to the new one.
            guard self.selectedBuild == build else { return }
            if let attributed = self.attributedPids, !pids.isSubset(of: attributed) {
                self.attributedPids = attributed.union(pids)
            }
        }
    }

    private func startPidRefreshTimer() {
        stopPidRefreshTimer()
        guard selectedBuild != nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            self?.refreshBuildPidsFromState()
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

    private func publishBuildPids(_ pids: Set<String>?) {
        let sorted = (pids ?? []).sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
        DispatchQueue.main.async {
            if self.buildPids != sorted {
                self.buildPids = sorted
            }
        }
    }

    /// The processes named like `build`, narrowed down to those of its bundle when `devicectl` can tell.
    /// Without Xcode, the production and integration builds of an app cannot be told apart.
    /// Blocks while the tools run.
    private func runningPids(for build: IOSAppBuild, device: Device) -> Set<String> {
        guard let syslogPath = IOSTool.locate("idevicesyslog"),
              let output = IOSTool.run(syslogPath, Self.connectionArguments(for: device) + ["pidlist"])
        else { return [] }

        let candidates = Self.pids(inPidList: output, matching: [build.processName])
        guard !candidates.isEmpty,
              let bundleIDs = attribution.bundleIdentifiers(of: candidates, on: device)
        else { return candidates }
        return candidates.filter { bundleIDs[$0] == build.id }
    }

    /// Extracts the PIDs of `processNames` from `idevicesyslog pidlist` (`<pid> <name>` per line)
    static func pids(inPidList output: String, matching processNames: [String]) -> Set<String> {
        var pids: Set<String> = []

        for line in output.split(whereSeparator: \.isNewline) {
            let columns = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard columns.count == 2, Int(columns[0]) != nil else { continue }

            if processNames.contains(columns[1].trimmingCharacters(in: .whitespaces)) {
                pids.insert(String(columns[0]))
            }
        }

        return pids
    }

    // MARK: - Devices

    /// Whether libimobiledevice is installed
    static var isAvailable: Bool {
        IOSTool.locate("idevicesyslog") != nil && IOSTool.locate("idevice_id") != nil
    }

    /// The iPhones reachable over USB or Wi-Fi. Blocks while the tools run: call it off the main queue.
    static func listDevices() -> [Device] {
        guard let ideviceIdPath = IOSTool.locate("idevice_id") else { return [] }

        // A device reachable both ways is used over the cable, which is faster and steadier
        let usb = udids(in: IOSTool.run(ideviceIdPath, ["-l"]))
        let wireless = udids(in: IOSTool.run(ideviceIdPath, ["-n"])).filter { !usb.contains($0) }

        return usb.map { device(udid: $0, isWireless: false, ideviceIdPath: ideviceIdPath) }
            + wireless.map { device(udid: $0, isWireless: true, ideviceIdPath: ideviceIdPath) }
    }

    private static func device(udid: String, isWireless: Bool, ideviceIdPath: String) -> Device {
        // `idevice_id <udid>` prints the name the user gave the device
        let arguments = (isWireless ? ["-n"] : []) + [udid]
        let name = IOSTool.run(ideviceIdPath, arguments)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Device(id: udid, name: name.isEmpty ? udid : name, platform: .ios, isWireless: isWireless)
    }

    /// The UDIDs listed by `idevice_id -l` / `-n`, one per line, without duplicates
    static func udids(in output: String?) -> [String] {
        var seen: Set<String> = []
        return (output ?? "")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

// MARK: - Tools

/// Finds and runs libimobiledevice's command-line tools
enum IOSTool {
    /// Homebrew prefixes on Apple silicon and Intel Macs
    static let searchDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// The path of the executable `name`, or `nil` when it is not installed.
    /// Resolved on every use so a tool installed while the app runs is picked up on refresh.
    static func locate(_ name: String) -> String? {
        searchDirectories
            .map { "\($0)/\(name)" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs a short-lived command and returns its stdout, or `nil` on failure
    static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice

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

// MARK: - Process Attribution

/// Tells which app each process of an iOS device belongs to, through Xcode's `devicectl`.
/// The builds of an app share their executable name, so their PID is all that tells them apart.
final class ProcessAttribution {
    /// Per device, the bundle identifier of every PID seen so far ("" for processes that are not apps)
    private var bundleIDsByDevice: [String: [String: String]] = [:]
    private let lock = NSLock()

    /// The bundle identifier of each of `pids` that devicectl knows, or `nil` when devicectl is not
    /// available (no Xcode) or cannot reach the device. devicectl takes about a second, so it only
    /// runs when one of `pids` is new: a PID keeps its app while it runs.
    func bundleIdentifiers(of pids: Set<String>, on device: Device) -> [String: String]? {
        lock.lock()
        var bundleIDs = bundleIDsByDevice[device.id] ?? [:]
        lock.unlock()

        if !pids.isSubset(of: bundleIDs.keys) {
            guard let fresh = Self.fetchBundleIdentifiers(device: device) else { return nil }
            bundleIDs = fresh
            lock.lock()
            bundleIDsByDevice[device.id] = fresh
            lock.unlock()
        }
        return bundleIDs.filter { pids.contains($0.key) }
    }

    /// The bundle identifier of `pid` from the last devicectl run, without running it again
    func cachedBundleIdentifier(of pid: String, on device: Device) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return bundleIDsByDevice[device.id]?[pid]
    }

    private static func fetchBundleIdentifiers(device: Device) -> [String: String]? {
        guard let apps = devicectlResult(["device", "info", "apps"], device: device),
              let processes = devicectlResult(["device", "info", "processes"], device: device)
        else { return nil }
        return bundleIdentifiers(apps: apps, processes: processes)
    }

    /// Runs a devicectl command and returns the `result` of its JSON output
    private static func devicectlResult(_ arguments: [String], device: Device) -> [String: Any]? {
        let command = ["devicectl"] + arguments + ["--device", device.id, "--quiet", "--json-output", "-"]
        guard let output = IOSTool.run("/usr/bin/xcrun", command),
              let json = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        else { return nil }
        return json["result"] as? [String: Any]
    }

    /// Pairs each running process with the app bundle holding its executable:
    /// `…/Application/<UUID>/Picta.app/Picta` runs from the app installed at `…/Application/<UUID>/Picta.app/`
    static func bundleIdentifiers(apps: [String: Any], processes: [String: Any]) -> [String: String] {
        var bundleIDsByURL: [String: String] = [:]
        for app in apps["apps"] as? [[String: Any]] ?? [] {
            if let url = app["url"] as? String, let bundleID = app["bundleIdentifier"] as? String {
                bundleIDsByURL[url] = bundleID
            }
        }

        var bundleIDs: [String: String] = [:]
        for process in processes["runningProcesses"] as? [[String: Any]] ?? [] {
            guard let pid = process["processIdentifier"] as? Int else { continue }
            let executable = process["executable"] as? String ?? ""
            let bundleURL = executable.range(of: ".app/", options: .backwards)
                .map { String(executable[..<$0.upperBound]) }
            bundleIDs[String(pid)] = bundleURL.flatMap { bundleIDsByURL[$0] } ?? ""
        }
        return bundleIDs
    }
}
