import Foundation

class ADBManager: ObservableObject {
    @Published var logLines: [String] = []

    
    private var task: Process?
    private var pipe: Pipe?
    
    @Published var isLogcatRunning = false
    
    @Published var connectedDevices: [String] = []
    @Published var selectedDevice: String? = nil

    
    // Update this to your actual adb path
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
            DispatchQueue.main.async {
                self.isLogcatRunning = false
            }
        }
    }

    func startLogcat() {
        guard FileManager.default.isExecutableFile(atPath: adbPath) else {
            print("❌ ADB not found at \(adbPath)")
            return
        }

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

        do {
            try task?.run()
            print("✅ Logcat started")
            DispatchQueue.main.async {
                self.isLogcatRunning = true
            }

            // Read asynchronously line by line
            DispatchQueue.global(qos: .background).async { [weak self] in
                let bufferSize = 4096
                var leftoverData = Data()

                while self?.task?.isRunning == true {
                    autoreleasepool {
                        if let data = try? fileHandle.read(upToCount: bufferSize), !data.isEmpty {
                            leftoverData.append(data)

                            // Split by newline characters
                            while true {
                                if let range = leftoverData.range(of: Data([0x0A])) { // newline '\n' byte
                                    let lineData = leftoverData.subdata(in: 0..<range.lowerBound)
                                    leftoverData.removeSubrange(0...range.lowerBound)

                                    if let line = String(data: lineData, encoding: .utf8) {
                                        DispatchQueue.main.async {
                                            self?.logLines.append(line)
                                            // Optional: limit log buffer size to last 5000 lines
                                            if self?.logLines.count ?? 0 > 5000 {
                                                self?.logLines.removeFirst()
                                            }
                                        }
                                    }
                                } else {
                                    // No full line yet, wait for more data
                                    break
                                }
                            }
                        }
                    }
                }
            }
        } catch {
            DispatchQueue.main.async {
                self.isLogcatRunning = false
            }
            print("❌ Failed to run adb logcat: \(error)")
        }
    }


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

    
    func stopLogcat() {
        task?.terminate()
        task = nil
        DispatchQueue.main.async {
            self.isLogcatRunning = false
        }
        print("🛑 Logcat stopped")
    }
}
