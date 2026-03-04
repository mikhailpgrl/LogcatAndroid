import Foundation

class ADBManager: ObservableObject {
    @Published var logEntries: [LogEntry] = []
    @Published var isLogcatRunning = false
    @Published var connectedDevices: [String] = []
    @Published var selectedDevice: String? = nil

    private var task: Process?
    private var pipe: Pipe?
    private var entryIndex: Int = 0

    /// Pending entries accumulated on the background thread, flushed periodically
    private var pendingEntries: [LogEntry] = []
    private let pendingLock = NSLock()
    private var flushTimer: DispatchSourceTimer?

    /// Only log lines whose tag starts with this prefix are kept
    private let tagFilter = "enqueueLog"

    let adbPath: String = "/opt/homebrew/bin/adb"

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

        pipe = Pipe()
        task = Process()
        task?.executableURL = URL(fileURLWithPath: adbPath)
        if let device = selectedDevice {
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

                while self.task?.isRunning == true {
                    autoreleasepool {
                        if let data = try? fileHandle.read(upToCount: bufferSize), !data.isEmpty {
                            leftoverData.append(data)

                            while let range = leftoverData.range(of: Data([0x0A])) {
                                let lineData = leftoverData.subdata(in: 0..<range.lowerBound)
                                leftoverData.removeSubrange(0...range.lowerBound)

                                guard let line = String(data: lineData, encoding: .utf8) else { continue }

                                // Only keep lines that contain "enqueueLog"
                                guard line.contains(self.tagFilter) else { continue }

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
                self.flushToMain()
            }
        } catch {
            stopFlushTimer()
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
        flushToMain()
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
            self.logEntries.append(contentsOf: batch)
            // Limit buffer to last 5000 entries
            if self.logEntries.count > 5000 {
                self.logEntries.removeFirst(self.logEntries.count - 5000)
            }
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
                    self.connectedDevices = deviceIDs
                    if !deviceIDs.contains(self.selectedDevice ?? "") {
                        self.selectedDevice = deviceIDs.first
                    }
                }
            }
        } catch {
            print("❌ Failed to get devices: \(error)")
        }
    }
}
