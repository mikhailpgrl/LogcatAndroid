//
//  CompareSession.swift
//  LogCatAndroid
//

import Foundation

/// What the compare window opens with: the two devices and the apps picked in the main window
struct CompareRequest: Codable, Hashable {
    let left: Device
    let right: Device
    /// `AppPackage` raw value followed on Android devices, `nil` for "all apps"
    let androidPackage: String?
    /// `IOSAppBuild` id followed on iOS devices, `nil` for "all apps"
    let iosBuildID: String?
}

/// The analytics of two devices streamed side by side. While comparing, their events are paired
/// and those that differ are recorded; stopping saves them as a JSON report.
@MainActor
final class CompareSession: ObservableObject {
    let request: CompareRequest
    /// Each side streams its own device with its own manager, independently of the main window,
    /// so two devices of the same platform can be compared too
    let left: LogStreamManager
    let right: LogStreamManager

    @Published private(set) var isComparing = false
    /// The differences found by the current (or last) comparison, newest last
    @Published private(set) var mismatches: [CompareMismatch] = []
    /// Events paired between the two devices, matching or not
    @Published private(set) var pairedCount = 0
    /// The report written when the last comparison stopped
    @Published private(set) var savedReportURL: URL?
    @Published private(set) var saveError: String?

    /// Differences the user chose not to see. Applied when displaying and saving rather than while
    /// comparing, so removing a rule brings its differences back.
    let ignoreStore = CompareIgnoreStore.shared

    private var comparator = LogComparator()
    /// Entries already fed to the comparator, per side
    private var processedIDs: [CompareSide: Set<UUID>] = [.left: [], .right: []]
    private var pollTask: Task<Void, Never>?
    private var startedAt: Date?

    init(request: CompareRequest) {
        self.request = request
        left = Self.makeManager(for: request.left, request: request)
        right = Self.makeManager(for: request.right, request: request)
    }

    func manager(for side: CompareSide) -> LogStreamManager {
        side == .left ? left : right
    }

    func device(for side: CompareSide) -> Device {
        side == .left ? request.left : request.right
    }

    /// The app followed on `side`, e.g. "PhotoPrint" or "Picta · Int"
    func appLabel(for side: CompareSide) -> String {
        switch device(for: side).platform {
        case .android:
            return request.androidPackage.flatMap(AppPackage.init(rawValue:))?.displayName ?? "All apps"
        case .ios:
            return request.iosBuildID.flatMap(IOSAppBuild.build(withID:))?.shortLabel ?? "All apps"
        }
    }

    private static func makeManager(for device: Device, request: CompareRequest) -> LogStreamManager {
        switch device.platform {
        case .android:
            let manager = AndroidLogManager()
            manager.selectedPackage = request.androidPackage.flatMap(AppPackage.init(rawValue:))
            manager.selectedDevice = device.id
            return manager
        case .ios:
            let manager = IOSLogManager()
            manager.selectedBuild = request.iosBuildID.flatMap(IOSAppBuild.build(withID:))
            manager.selectedDevice = device
            return manager
        }
    }

    // MARK: - Streams

    /// Starts streaming both devices, shown live whether or not a comparison runs
    func startStreams() {
        if !left.isLogcatRunning { left.startLogcat() }
        if !right.isLogcatRunning { right.startLogcat() }
    }

    func stopStreams() {
        if isComparing { stopCompare() }
        left.stopLogcat()
        right.stopLogcat()
    }

    // MARK: - Comparison

    /// Starts pairing the events logged from now on. Events already on screen are not compared.
    func startCompare() {
        guard !isComparing else { return }
        startStreams()

        comparator = LogComparator()
        mismatches = []
        pairedCount = 0
        savedReportURL = nil
        saveError = nil
        startedAt = Date()
        processedIDs = [
            .left: Set(left.displayedEntries.map(\.id)),
            .right: Set(right.displayedEntries.map(\.id)),
        ]
        isComparing = true

        // The managers publish their entries in batches: pick up the new ones a few times a second
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                self?.ingestNewEntries()
            }
        }
    }

    /// Stops pairing: events still waiting for their partner are recorded as missing on the other
    /// device, then the differences are saved as a JSON report
    func stopCompare() {
        guard isComparing else { return }
        pollTask?.cancel()
        pollTask = nil
        ingestNewEntries()
        mismatches += comparator.finish()
        isComparing = false
        saveReport()
    }

    /// Empties both devices' logs and the differences. A running comparison goes on from a clean
    /// slate: events waiting for their partner are dropped rather than reported as missing.
    func clear() {
        left.clearLogs()
        right.clearLogs()
        mismatches = []
        pairedCount = 0
        comparator = LogComparator()
        // The managers drop their entries asynchronously: mark those still listed as processed
        // so the next poll does not feed them again before they are gone
        processedIDs = [
            .left: Set(left.displayedEntries.map(\.id)),
            .right: Set(right.displayedEntries.map(\.id)),
        ]
    }

    /// Feeds the comparator the entries each side displayed since the last call, in log order
    private func ingestNewEntries() {
        for side in [CompareSide.left, .right] {
            for entry in manager(for: side).displayedEntries where !(processedIDs[side]?.contains(entry.id) ?? false) {
                processedIDs[side]?.insert(entry.id)
                if let mismatch = comparator.add(entry, from: side) {
                    mismatches.append(mismatch)
                }
            }
        }
        if pairedCount != comparator.pairedCount {
            pairedCount = comparator.pairedCount
        }
    }

    /// The recorded differences without what `rules` ignore
    func visibleMismatches(ignoring rules: [CompareIgnoreRule]) -> [CompareMismatch] {
        mismatches.compactMap { $0.applying(rules) }
    }

    // MARK: - Report

    /// What is saved when a comparison stops
    struct Report: Codable {
        struct Side: Codable {
            let device: Device
            let app: String
        }

        let startedAt: Date
        let endedAt: Date
        let left: Side
        let right: Side
        let pairedEvents: Int
        /// The differences left once `ignoreRules` are applied
        let mismatches: [CompareMismatch]
        let ignoreRules: [CompareIgnoreRule]
    }

    /// Where the reports are saved: `~/Library/Application Support/LogCatAndroid/Comparisons`
    static var reportsDirectory: URL {
        URL.applicationSupportDirectory
            .appending(path: "LogCatAndroid", directoryHint: .isDirectory)
            .appending(path: "Comparisons", directoryHint: .isDirectory)
    }

    private func saveReport() {
        let endedAt = Date()
        let report = Report(
            startedAt: startedAt ?? endedAt,
            endedAt: endedAt,
            left: Report.Side(device: request.left, app: appLabel(for: .left)),
            right: Report.Side(device: request.right, app: appLabel(for: .right)),
            pairedEvents: pairedCount,
            mismatches: visibleMismatches(ignoring: ignoreStore.rules),
            ignoreRules: ignoreStore.rules
        )

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let url = Self.reportsDirectory.appending(path: "compare-\(formatter.string(from: endedAt)).json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: Self.reportsDirectory, withIntermediateDirectories: true)
            try encoder.encode(report).write(to: url, options: .atomic)
            savedReportURL = url
        } catch {
            saveError = "Could not save the report: \(error.localizedDescription)"
        }
    }
}
