import Foundation

class ADBManager: ObservableObject {
    /// How many entries are kept, oldest dropped first. "All logs" captures around 100 lines/s
    /// while the app is in use, so this holds about a quarter of an hour.
    static let maxEntries = 100_000

    @Published var logEntries: [LogEntry] = []
    /// Every tag seen since the last clear, sorted, for the filter bar.
    /// Kept up to date as entries come in, so the view does not scan the whole buffer on every refresh.
    @Published private(set) var seenTags: [String] = []
    @Published var isLogcatRunning = false
    @Published var connectedDevices: [Device] = []

    @Published var selectedDevice: Device? = nil {
        didSet {
            // A refreshed instance of the same device (possibly renamed) is still the same selection,
            // unless it is now reached another way (USB ↔ Wi-Fi): the stream must be restarted then
            guard oldValue?.id != selectedDevice?.id || oldValue?.isWireless != selectedDevice?.isWireless
            else { return }
            deviceSelectionChanged(from: oldValue)
        }
    }

    /// The platforms whose command-line tools are not installed, so their devices cannot be listed
    @Published private(set) var platformsMissingTools: [DevicePlatform] = []

    /// The build whose logs are displayed, one of the selected device's platform. `nil` means "all apps".
    /// Each platform remembers its own selection.
    @Published var selectedBuild: AppBuild? {
        didSet { buildSelectionChanged(from: oldValue) }
    }

    /// The platform whose builds the app picker lists: the selected device's
    var currentPlatform: DevicePlatform {
        selectedDevice?.platform ?? .android
    }

    /// Whether only the analytics events or every log of the followed apps are captured
    @Published var captureMode: CaptureMode {
        didSet { captureModeChanged(from: oldValue) }
    }

    /// PIDs currently running `selectedBuild` on the selected device (empty when it is not running)
    @Published private(set) var buildPids: [String] = []

    /// Every PID attributed to `selectedBuild` during the current stream, when its entries are told
    /// apart at display time: the builds of an iOS app share their process, so the stream carries
    /// them all, and a PID is only attributed a moment after the app starts. Filtering the display
    /// rather than the capture keeps the first events of a freshly launched build.
    /// `nil` when every captured entry belongs to the selection.
    @Published private(set) var attributedPids: Set<String>?

    private var task: Process?
    private var pipe: Pipe?
    private var entryIndex: Int = 0

    /// Pending entries accumulated on the background thread, flushed periodically
    private var pendingEntries: [LogEntry] = []
    private let pendingLock = NSLock()
    private var flushTimer: DispatchSourceTimer?

    /// State shared with the background threads (reader + PID refresher), guarded by `stateLock`
    private struct FilterState {
        var build: AppBuild?
        var device: Device?
        var mode: CaptureMode = .analytics
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

    /// Set while the build selection is swapped for another platform's, which is not a user choice
    private var isSwitchingPlatform = false

    private static let captureModeKey = "captureMode"

    private static func selectedBuildKey(for platform: DevicePlatform) -> String {
        "selectedBuild.\(platform.rawValue)"
    }

    private static func storedBuild(for platform: DevicePlatform) -> AppBuild? {
        UserDefaults.standard.string(forKey: selectedBuildKey(for: platform)).flatMap(AppBuild.build(withID:))
    }

    private let androidBridge = AndroidBridge()
    private let iosBridge = IOSBridge()

    private var bridges: [DeviceBridge] { [androidBridge, iosBridge] }

    private func bridge(for platform: DevicePlatform) -> DeviceBridge {
        switch platform {
        case .android: return androidBridge
        case .ios: return iosBridge
        }
    }

    init() {
        // No device yet: the default platform's selection, swapped when a device of the other one shows up
        selectedBuild = Self.storedBuild(for: .android)
        let storedMode = UserDefaults.standard.string(forKey: Self.captureModeKey)
        captureMode = storedMode.flatMap(CaptureMode.init(rawValue:)) ?? .analytics
        filterState.build = selectedBuild
        filterState.mode = captureMode
    }

    func startLogcat() {
        guard let device = selectedDevice else {
            print("❌ No device selected")
            return
        }

        let bridge = bridge(for: device.platform)
        let build = selectedBuild
        let mode = captureMode
        guard let command = bridge.streamCommand(device: device, build: build, mode: mode) else {
            print("❌ \(device.platform.displayName) tools not found — \(bridge.installCommand)")
            return
        }

        entryIndex = 0
        pendingLock.lock()
        pendingEntries.removeAll()
        pendingLock.unlock()

        // Resolve the PIDs of the selected build before reading, so the very first
        // lines are already filtered.
        let followedBuilds = Self.followedBuilds(build, mode: mode, platform: device.platform)
        let pids = Self.runningPids(of: followedBuilds, bridge: bridge, device: device)
        attributedPids = Self.attributesPids(build: build, platform: device.platform) ? (pids ?? []) : nil

        stateLock.lock()
        filterState.device = device
        filterState.build = build
        filterState.mode = mode
        filterState.pids = pids
        filterState.generation += 1
        let generation = filterState.generation
        stateLock.unlock()

        publishBuildPids(pids)

        if let build, let pids, pids.isEmpty {
            print("⚠️ \(build.id) is not running — no logs will match until it starts")
        }

        pipe = Pipe()
        task = Process()
        task?.executableURL = command.executable
        task?.arguments = command.arguments

        task?.standardOutput = pipe
        task?.standardError = pipe

        guard let fileHandle = pipe?.fileHandleForReading else {
            print("❌ Failed to create pipe for the log stream")
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

            let platform = device.platform
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                var leftoverData = Data()
                var reachedEnd = false

                while !reachedEnd, self.task?.isRunning == true, self.isCurrentGeneration(generation) {
                    autoreleasepool {
                        // PIDs are refreshed periodically, so re-read the filter on every chunk
                        let (activePids, activeBuild) = self.currentFilter()

                        // `availableData` returns as soon as anything was written, whereas `read(upToCount:)`
                        // waits for the full count: a sparse (filtered) stream would only show up every 8 KB.
                        let data = fileHandle.availableData
                        // An empty read is the end of the stream: the tool exited
                        reachedEnd = data.isEmpty

                        if !data.isEmpty {
                            leftoverData.append(data)

                            while let range = leftoverData.range(of: Data([0x0A])) {
                                let lineData = leftoverData.subdata(in: 0..<range.lowerBound)
                                leftoverData.removeSubrange(0...range.lowerBound)

                                guard let line = String(data: lineData, encoding: .utf8) else { continue }

                                // Only keep the analytics lines of the selected app
                                guard Self.shouldKeep(line: line, build: activeBuild, platform: platform, mode: mode)
                                else { continue }

                                // Only keep lines emitted by the selected build's process(es).
                                // iOS builds are told apart at display time (see `attributedPids`).
                                if platform == .android, let activePids {
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
            print("❌ Failed to start the log stream: \(error)")
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
            self.seenTags.removeAll()
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
            // Each in-place mutation of a @Published array copies it whole: detach the buffer
            // so it is uniquely referenced, mutate it, then publish it back once.
            var entries = self.logEntries
            self.logEntries = []

            for entry in batch {
                // The same event is often logged once per analytics backend, under a different
                // tag each time: fold those duplicates into a single entry carrying every tag.
                if let index = Self.indexOfSameEvent(as: entry, in: entries) {
                    entries[index].merge(entry)
                } else {
                    entries.append(entry)
                }
            }
            if entries.count > Self.maxEntries {
                entries.removeFirst(entries.count - Self.maxEntries)
            }
            self.logEntries = entries

            // Tags of dropped entries stay listed until the next clear
            let newTags = Set(batch.flatMap(\.tags)).subtracting(self.seenTags)
            if !newTags.isEmpty {
                self.seenTags = (self.seenTags + newTags).sorted()
            }
        }
    }

    /// Looks back through the most recent entries for the same event logged under another tag.
    /// Duplicates are emitted back to back, so a short window is enough.
    private static func indexOfSameEvent(as entry: LogEntry, in entries: [LogEntry]) -> Int? {
        let window = 50
        let lowerBound = max(0, entries.count - window)
        for index in stride(from: entries.count - 1, through: lowerBound, by: -1)
        where entries[index].isSameEvent(as: entry) {
            return index
        }
        return nil
    }

    // MARK: - Build Filtering

    /// Called on the main queue whenever the user picks another build
    private func buildSelectionChanged(from oldValue: AppBuild?) {
        guard oldValue != selectedBuild, !isSwitchingPlatform else { return }
        UserDefaults.standard.set(selectedBuild?.id, forKey: Self.selectedBuildKey(for: currentPlatform))

        if isLogcatRunning {
            // The buffered logs belong to the previous app: restart from a clean slate
            stopLogcat()
            clearLogs()
            startLogcat()
        } else {
            refreshBuildPids()
        }
    }

    /// Called on the main queue whenever the capture mode changes
    private func captureModeChanged(from oldValue: CaptureMode) {
        guard oldValue != captureMode else { return }
        UserDefaults.standard.set(captureMode.rawValue, forKey: Self.captureModeKey)

        if isLogcatRunning {
            // The buffered logs were captured with the other mode: restart from a clean slate
            stopLogcat()
            clearLogs()
            startLogcat()
        } else {
            refreshBuildPids()
        }
    }

    /// Called on the main queue whenever another device gets selected
    private func deviceSelectionChanged(from oldDevice: Device?) {
        // Builds are per platform: bring back the one last picked for the new device's platform
        if let platform = selectedDevice?.platform, platform != oldDevice?.platform {
            isSwitchingPlatform = true
            selectedBuild = Self.storedBuild(for: platform)
            isSwitchingPlatform = false
        }

        if isLogcatRunning, selectedDevice != nil {
            // The buffered logs come from the previous device: restart from a clean slate
            stopLogcat()
            clearLogs()
            startLogcat()
        } else {
            refreshBuildPids()
        }
    }

    /// Re-resolves the PIDs of the selected build. Must be called from the main queue.
    func refreshBuildPids() {
        let device = selectedDevice
        let build = selectedBuild
        let mode = captureMode

        stateLock.lock()
        filterState.device = device
        filterState.build = build
        filterState.mode = mode
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
        let mode = filterState.mode
        stateLock.unlock()

        guard let device, let builds = Self.followedBuilds(build, mode: mode, platform: device.platform) else {
            stateLock.lock()
            filterState.pids = nil
            stateLock.unlock()
            publishBuildPids(nil)
            return
        }

        let pids = Self.runningPids(of: builds, bridge: bridge(for: device.platform), device: device)

        stateLock.lock()
        // Only apply if the selection did not change while the tool was running
        guard filterState.build == build, filterState.device == device, filterState.mode == mode else {
            stateLock.unlock()
            return
        }
        filterState.pids = pids
        stateLock.unlock()

        publishBuildPids(pids)
        if let pids, Self.attributesPids(build: build, platform: device.platform) {
            DispatchQueue.main.async {
                // Only while a stream attributes PIDs: stopped, the display keeps what was captured
                if let attributed = self.attributedPids, !pids.isSubset(of: attributed) {
                    self.attributedPids = attributed.union(pids)
                }
            }
        }
    }

    private func startPidRefreshTimer() {
        stopPidRefreshTimer()
        guard let platform = selectedDevice?.platform,
              Self.followedBuilds(selectedBuild, mode: captureMode, platform: platform) != nil else { return }

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

    private func currentFilter() -> (pids: Set<String>?, build: AppBuild?) {
        stateLock.lock()
        defer { stateLock.unlock() }
        return (filterState.pids, filterState.build)
    }

    /// Whether a raw log line from a `platform` device should be captured for `build`.
    /// With no build selected ("all apps"), a line is kept if it fits any known build of the platform.
    static func shouldKeep(line: String, build: AppBuild?, platform: DevicePlatform, mode: CaptureMode) -> Bool {
        let builds = build.map { [$0] } ?? AppBuild.builds(for: platform)

        switch (mode, platform) {
        case (.analytics, _):
            return builds.contains { $0.isAnalyticsLine(line) }
        case (.all, .android):
            // Narrowed down to the apps' processes by the PID filter
            return true
        case (.all, .ios):
            return builds.contains { $0.isIOSLineFromProcess(line) }
        }
    }

    /// The builds whose PIDs are resolved, or `nil` when no PID is needed: "all apps" recognizes
    /// analytics by their format and iOS logs by their process name. Capturing every Android log
    /// of "all apps" follows the processes of every known build instead.
    private static func followedBuilds(_ build: AppBuild?, mode: CaptureMode, platform: DevicePlatform) -> [AppBuild]? {
        if let build { return [build] }
        return platform == .android && mode == .all ? AppBuild.builds(for: .android) : nil
    }

    /// Whether the entries of `build` are told apart by PID at display time (see `attributedPids`)
    private static func attributesPids(build: AppBuild?, platform: DevicePlatform) -> Bool {
        platform == .ios && build != nil
    }

    /// The PIDs of every running process of `builds`, or `nil` when `builds` is `nil`
    private static func runningPids(of builds: [AppBuild]?, bridge: DeviceBridge, device: Device) -> Set<String>? {
        builds.map { builds in
            builds.reduce(into: Set<String>()) { pids, build in
                pids.formUnion(bridge.runningPids(for: build, device: device))
            }
        }
    }

    private func publishBuildPids(_ pids: Set<String>?) {
        let sorted = (pids ?? []).sorted { (Int($0) ?? 0) < (Int($1) ?? 0) }
        DispatchQueue.main.async {
            if self.buildPids != sorted {
                self.buildPids = sorted
            }
        }
    }

    // MARK: - Devices

    /// Lists the devices of every platform whose tools are installed, off the main queue
    func refreshDevices() {
        let bridges = self.bridges

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var devices: [Device] = []
            var platformsMissingTools: [DevicePlatform] = []
            for bridge in bridges {
                if bridge.isAvailable {
                    devices += bridge.listDevices()
                } else {
                    platformsMissingTools.append(bridge.platform)
                }
            }

            DispatchQueue.main.async {
                self?.applyDevices(devices, platformsMissingTools: platformsMissingTools)
            }
        }
    }

    /// Publishes a fresh device list, keeping the current selection while it is still connected
    private func applyDevices(_ devices: [Device], platformsMissingTools: [DevicePlatform]) {
        let previousDevice = selectedDevice
        connectedDevices = devices
        if self.platformsMissingTools != platformsMissingTools {
            self.platformsMissingTools = platformsMissingTools
        }

        // Re-select the refreshed instance so the picker shows its current name
        selectedDevice = devices.first { $0.id == previousDevice?.id } ?? devices.first

        // A device change already refreshes the PIDs through `selectedDevice`
        if selectedDevice?.id == previousDevice?.id {
            refreshBuildPids()
        }

        // With a single device there is nothing to choose: start streaming right away.
        // Only once, so a manual Stop is not undone by a later device refresh.
        if devices.count == 1, !hasAutoStarted, !isLogcatRunning {
            hasAutoStarted = true
            startLogcat()
        }
    }
}
