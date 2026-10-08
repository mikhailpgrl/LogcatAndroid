//
//  ShellCommand.swift
//  LogCatAndroid
//

import Foundation

/// The outcome of a finished command-line tool
struct ShellResult {
    let status: Int32
    /// Combined stdout + stderr
    let output: String

    var succeeded: Bool { status == 0 }
}

enum ShellError: LocalizedError {
    case executableNotFound(String)
    case failed(command: String, status: Int32, output: String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound(let path):
            return "Executable not found: \(path)"
        case .failed(let command, let status, let output):
            // The tail of the output usually carries the actual reason
            let tail = output
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .suffix(3)
                .joined(separator: " · ")
            return "\(command) failed (exit \(status))" + (tail.isEmpty ? "" : ": \(tail)")
        }
    }
}

/// Runs command-line tools (git, gradlew, adb, aapt2) asynchronously, streaming their
/// output line by line. Only one command runs at a time per instance so it can be cancelled.
final class ShellCommand {
    /// The process currently running, terminated when the calling task is cancelled
    private var process: Process?
    private let lock = NSLock()

    /// Runs `executable` with `arguments` and waits for it to exit.
    /// Every line of output is forwarded to `onOutput` (from a background thread) as it arrives.
    func run(
        _ executable: String,
        _ arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil,
        onOutput: ((String) -> Void)? = nil
    ) async throws -> ShellResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ShellError.executableNotFound(executable)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        if let environment {
            process.environment = environment
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // Never let a tool wait on an interactive prompt
        process.standardInput = FileHandle.nullDevice

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                lock.lock()
                self.process = process
                lock.unlock()

                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let fileHandle = pipe.fileHandleForReading
                    var output = ""
                    var leftover = Data()

                    // Read until EOF, emitting complete lines as they come in
                    while let data = try? fileHandle.read(upToCount: 4096), !data.isEmpty {
                        leftover.append(data)
                        while let range = leftover.range(of: Data([0x0A])) {
                            let lineData = leftover.subdata(in: 0..<range.lowerBound)
                            leftover.removeSubrange(0...range.lowerBound)
                            let line = String(decoding: lineData, as: UTF8.self)
                            output += line + "\n"
                            onOutput?(line)
                        }
                    }
                    if !leftover.isEmpty {
                        let line = String(decoding: leftover, as: UTF8.self)
                        output += line
                        onOutput?(line)
                    }

                    process.waitUntilExit()

                    if let self {
                        self.lock.lock()
                        if self.process === process { self.process = nil }
                        self.lock.unlock()
                    }

                    continuation.resume(returning: ShellResult(status: process.terminationStatus, output: output))
                }
            }
        } onCancel: {
            terminate()
        }
    }

    /// Runs a command and throws `ShellError.failed` when it exits with a non-zero status
    @discardableResult
    func runChecked(
        _ executable: String,
        _ arguments: [String],
        currentDirectory: URL? = nil,
        environment: [String: String]? = nil,
        onOutput: ((String) -> Void)? = nil
    ) async throws -> String {
        let result = try await run(executable, arguments, currentDirectory: currentDirectory,
                                   environment: environment, onOutput: onOutput)
        guard result.succeeded else {
            let name = (executable as NSString).lastPathComponent
            let command = ([name] + arguments.prefix(2)).joined(separator: " ")
            throw ShellError.failed(command: command, status: result.status, output: result.output)
        }
        return result.output
    }

    /// Stops the running command, if any
    func terminate() {
        lock.lock()
        let running = process
        lock.unlock()
        guard let running, running.isRunning else { return }
        running.terminate()
    }
}
