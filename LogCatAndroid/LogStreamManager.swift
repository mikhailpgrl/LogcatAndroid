//
//  LogStreamManager.swift
//  LogCatAndroid
//

import Foundation

/// The log buffer shared by the per-platform managers (`AndroidLogManager`, `IOSLogManager`).
/// It only batches parsed entries to the main queue and folds duplicates: how the logs are
/// streamed, filtered and attributed to an app is up to each platform's subclass.
class LogStreamManager: ObservableObject {
    /// How many entries are kept, oldest dropped first
    static let maxEntries = 5000

    @Published var logEntries: [LogEntry] = []
    @Published var isLogcatRunning = false

    /// Index of the next entry of the current stream. Only touched by the stream's reader thread.
    private var entryIndex: Int = 0

    /// Pending entries accumulated on the background thread, flushed periodically
    private var pendingEntries: [LogEntry] = []
    private let pendingLock = NSLock()
    private var flushTimer: DispatchSourceTimer?

    /// Starts streaming the selected device's logs. Implemented by each platform.
    func startLogcat() {
        preconditionFailure("\(type(of: self)) must override startLogcat()")
    }

    /// Stops the running stream. Implemented by each platform.
    func stopLogcat() {
        preconditionFailure("\(type(of: self)) must override stopLogcat()")
    }

    func clearLogs() {
        pendingLock.lock()
        pendingEntries.removeAll()
        pendingLock.unlock()
        DispatchQueue.main.async {
            self.logEntries.removeAll()
        }
    }

    // MARK: - Stream Lifecycle Helpers

    /// Drops the entries of a previous stream that were not flushed yet. Call before starting a stream.
    func resetPendingEntries() {
        entryIndex = 0
        pendingLock.lock()
        pendingEntries.removeAll()
        pendingLock.unlock()
    }

    /// Parses a raw line kept by the platform's filters and queues it for the next flush.
    /// Called from the stream's reader thread.
    func enqueue(line: String) {
        let currentIndex = entryIndex
        entryIndex = currentIndex + 1
        let entry = LogEntry.parse(line: line, index: currentIndex)

        pendingLock.lock()
        pendingEntries.append(entry)
        pendingLock.unlock()
    }

    // MARK: - Batched Flush

    func startFlushTimer() {
        stopFlushTimer()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            self?.flushToMain()
        }
        timer.resume()
        flushTimer = timer
    }

    func stopFlushTimer() {
        flushTimer?.cancel()
        flushTimer = nil
    }

    func flushToMain() {
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
            if self.logEntries.count > Self.maxEntries {
                self.logEntries.removeFirst(self.logEntries.count - Self.maxEntries)
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
}
