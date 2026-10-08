//
//  DeviceBridge.swift
//  LogCatAndroid
//

import Foundation

/// The platform-specific half of log streaming: which command-line tool lists the devices,
/// streams their logs and resolves the running processes.
/// Bridges are stateless and may be used from any thread.
protocol DeviceBridge {
    var platform: DevicePlatform { get }

    /// Whether the command-line tools this bridge relies on are installed
    var isAvailable: Bool { get }

    /// The name of those tools, shown in the setup screen
    var toolName: String { get }

    /// The `brew` arguments installing those tools
    var brewInstallArguments: [String] { get }

    /// The devices currently connected. Blocks while the tool runs: call it off the main queue.
    func listDevices() -> [Device]

    /// The long-running command streaming `device`'s logs, or `nil` when the tool is missing.
    /// The stream may already be narrowed down to `build` and `mode`; lines are filtered again in-app.
    func streamCommand(device: Device, build: AppBuild?, mode: CaptureMode) -> (executable: URL, arguments: [String])?

    /// The PIDs of every running process of `build` on `device`. Blocks while the tool runs.
    func runningPids(for build: AppBuild, device: Device) -> Set<String>
}

extension DeviceBridge {
    /// The command that installs the tools, shown in the setup screen
    var installCommand: String {
        (["brew"] + brewInstallArguments).joined(separator: " ")
    }
}

// MARK: - Tools

/// Finds and runs the command-line tools the bridges rely on
enum Tool {
    /// Homebrew prefixes on Apple silicon and Intel Macs
    static let searchDirectories = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// The path of the executable `name`, or `nil` when it is not installed
    static func locate(_ name: String, extraDirectories: [String] = []) -> String? {
        (searchDirectories + extraDirectories)
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

// MARK: - Android

/// Streams `adb logcat` from Android devices
struct AndroidBridge: DeviceBridge {
    let platform = DevicePlatform.android
    let toolName = "adb"
    let brewInstallArguments = ["install", "--cask", "android-platform-tools"]

    /// Resolved on every use so a tool installed while the app runs is picked up on refresh
    private var adbPath: String? {
        // Android Studio installs its own copy of adb in the SDK
        Tool.locate("adb", extraDirectories: [NSHomeDirectory() + "/Library/Android/sdk/platform-tools"])
    }

    var isAvailable: Bool { adbPath != nil }

    func listDevices() -> [Device] {
        guard let output = runADB(["devices", "-l"], device: nil) else { return [] }
        return Self.devices(in: output)
    }

    func streamCommand(device: Device, build: AppBuild?, mode: CaptureMode) -> (executable: URL, arguments: [String])? {
        guard let adbPath else { return nil }
        return (URL(fileURLWithPath: adbPath), ["-s", device.id, "logcat"])
    }

    /// Resolves the PIDs of `build`'s package, including the `:suffix` child processes an app may spawn
    func runningPids(for build: AppBuild, device: Device) -> Set<String> {
        // The process list is the most reliable source: unlike `pidof` it also matches child processes
        for arguments in [["shell", "ps", "-A", "-o", "PID,NAME"], ["shell", "ps", "-A"]] {
            guard let output = runADB(arguments, device: device) else { continue }
            let pids = Self.pids(in: output, matching: build.processName)
            if !pids.isEmpty { return pids }
        }

        // Last resort on devices with an unusual `ps`: the exact process name
        guard let output = runADB(["shell", "pidof", build.processName], device: device) else { return [] }
        return Set(
            output
                .split(whereSeparator: { $0.isWhitespace })
                .map(String.init)
                .filter { Int($0) != nil }
        )
    }

    /// Parses `adb devices -l`, keeping only the authorized, online devices:
    /// `R58M123ABC   device usb:1-1 product:beyond1 model:SM_G973F device:beyond1 transport_id:1`
    static func devices(in output: String) -> [Device] {
        output.split(separator: "\n").compactMap { line in
            let columns = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard columns.count >= 2, columns[1] == "device" else { return nil }

            let serial = columns[0]
            let model = columns
                .first { $0.hasPrefix("model:") }
                .map { $0.dropFirst("model:".count).replacingOccurrences(of: "_", with: " ") }
            // `adb connect` devices are named `host:port`, paired ones `adb-<serial>._adb-tls-connect._tcp`
            let isWireless = serial.contains(":") || serial.contains("._tcp")
            return Device(id: serial, name: model ?? serial, platform: .android, isWireless: isWireless)
        }
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
            // `.debug` builds are separate packages, with builds of their own in `AppBuild.all`.
            if processName == package || processName.hasPrefix("\(package):") {
                pids.insert(pid)
            }
        }

        return pids
    }

    /// Runs a short-lived adb command and returns its stdout, or `nil` on failure
    private func runADB(_ arguments: [String], device: Device?) -> String? {
        guard let adbPath else { return nil }
        return Tool.run(adbPath, (device.map { ["-s", $0.id] } ?? []) + arguments)
    }
}

// MARK: - iOS

/// Streams the syslog of iOS devices through libimobiledevice's `idevicesyslog`, over USB or Wi-Fi.
/// Wi-Fi devices must be paired with this Mac and have "Show this iPhone when on Wi-Fi" enabled.
struct IOSBridge: DeviceBridge {
    let platform = DevicePlatform.ios
    let toolName = "libimobiledevice"
    let brewInstallArguments = ["install", "libimobiledevice"]

    /// Tells the builds of an app apart, as they share their process name
    private static let attribution = ProcessAttribution()

    private var idevicesyslogPath: String? { Tool.locate("idevicesyslog") }
    private var ideviceIdPath: String? { Tool.locate("idevice_id") }

    var isAvailable: Bool { idevicesyslogPath != nil && ideviceIdPath != nil }

    func listDevices() -> [Device] {
        guard let ideviceIdPath else { return [] }

        // A device reachable both ways is used over the cable, which is faster and steadier
        let usb = Self.udids(in: Tool.run(ideviceIdPath, ["-l"]))
        let wireless = Self.udids(in: Tool.run(ideviceIdPath, ["-n"])).filter { !usb.contains($0) }

        return usb.map { device(udid: $0, isWireless: false, ideviceIdPath: ideviceIdPath) }
            + wireless.map { device(udid: $0, isWireless: true, ideviceIdPath: ideviceIdPath) }
    }

    private func device(udid: String, isWireless: Bool, ideviceIdPath: String) -> Device {
        // `idevice_id <udid>` prints the name the user gave the device
        let arguments = (isWireless ? ["-n"] : []) + [udid]
        let name = Tool.run(ideviceIdPath, arguments)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Device(id: udid, name: name.isEmpty ? udid : name, platform: .ios, isWireless: isWireless)
    }

    /// The libimobiledevice arguments targeting `device`: without `-n` only USB devices are looked up
    private static func connectionArguments(for device: Device) -> [String] {
        (device.isWireless ? ["-n"] : []) + ["-u", device.id]
    }

    /// The UDIDs listed by `idevice_id -l` / `-n`, one per line, without duplicates
    static func udids(in output: String?) -> [String] {
        var seen: Set<String> = []
        return (output ?? "")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    func streamCommand(device: Device, build: AppBuild?, mode: CaptureMode) -> (executable: URL, arguments: [String])? {
        guard let idevicesyslogPath else { return nil }
        // The whole system log (~1000 lines/s) still comes from the device, but `idevicesyslog`
        // filters it before it reaches our pipe. Process names survive app relaunches, unlike PIDs.
        // The other builds sharing the process name come along: they are told apart by PID in-app.
        var processNames: [String] = []
        for name in (build.map { [$0] } ?? AppBuild.builds(for: .ios)).map(\.processName)
        where !processNames.contains(name) {
            processNames.append(name)
        }
        var arguments = Self.connectionArguments(for: device)
            + ["--no-colors", "-p", processNames.joined(separator: "|")]
        if mode == .analytics {
            arguments += ["-m", AnalyticsFormat.pictalyticsMarker]
        }
        return (URL(fileURLWithPath: idevicesyslogPath), arguments)
    }

    /// The processes named like `build`, narrowed down to those of its bundle when `devicectl` can tell.
    /// Without Xcode, the production and integration builds of an app cannot be told apart.
    func runningPids(for build: AppBuild, device: Device) -> Set<String> {
        guard let idevicesyslogPath,
              let output = Tool.run(idevicesyslogPath, Self.connectionArguments(for: device) + ["pidlist"])
        else { return [] }

        let candidates = Self.pids(inPidList: output, matching: [build.processName])
        guard !candidates.isEmpty,
              let bundleIDs = Self.attribution.bundleIdentifiers(of: candidates, on: device)
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
}

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

    private static func fetchBundleIdentifiers(device: Device) -> [String: String]? {
        guard let apps = devicectlResult(["device", "info", "apps"], device: device),
              let processes = devicectlResult(["device", "info", "processes"], device: device)
        else { return nil }
        return bundleIdentifiers(apps: apps, processes: processes)
    }

    /// Runs a devicectl command and returns the `result` of its JSON output
    private static func devicectlResult(_ arguments: [String], device: Device) -> [String: Any]? {
        let command = ["devicectl"] + arguments + ["--device", device.id, "--quiet", "--json-output", "-"]
        guard let output = Tool.run("/usr/bin/xcrun", command),
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
