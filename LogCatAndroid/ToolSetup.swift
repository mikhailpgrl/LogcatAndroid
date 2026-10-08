//
//  ToolSetup.swift
//  LogCatAndroid
//

import Foundation

/// The command-line tools the app relies on, and how to get them
enum ToolSetup {
    /// One bridge per platform, in the order the setup screen lists them
    static let bridges: [DeviceBridge] = [AndroidBridge(), IOSBridge()]

    /// Whether every platform's tools are installed. Reads the file system on each call.
    static var allToolsInstalled: Bool {
        bridges.allSatisfy(\.isAvailable)
    }

    /// Homebrew installs the tools. `nil` when it is not installed.
    static var brewPath: String? {
        Tool.locate("brew")
    }

    /// Homebrew's own installer asks for an administrator password: it has to run in Terminal
    static let homebrewInstallCommand =
        #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)""#

    static let homebrewURL = URL(string: "https://brew.sh")!
}

/// Runs `brew install` for a platform's tools, collecting its output for display
final class ToolInstaller: ObservableObject {
    enum State: Equatable {
        case idle
        case installing(DevicePlatform)
        case failed(DevicePlatform)
    }

    @Published private(set) var state = State.idle
    /// Everything brew printed, across installs
    @Published private(set) var log = ""

    /// The running brew, kept alive until it exits
    private var process: Process?

    var isInstalling: Bool {
        if case .installing = state { return true }
        return false
    }

    func install(_ bridge: DeviceBridge) {
        guard !isInstalling, let brewPath = ToolSetup.brewPath else { return }

        let platform = bridge.platform
        let process = Process()
        process.executableURL = URL(fileURLWithPath: brewPath)
        process.arguments = bridge.brewInstallArguments

        // Apps launched from the Finder get a bare PATH: give brew the one a shell would have
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = (Tool.searchDirectories + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
            .joined(separator: ":")
        // Nothing can answer a prompt: fail instead of waiting forever
        environment["NONINTERACTIVE"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let output = pipe.fileHandleForReading
        output.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { self?.log += text }
        }

        process.terminationHandler = { [weak self] process in
            output.readabilityHandler = nil
            let rest = String(decoding: output.readDataToEndOfFile(), as: UTF8.self)
            let succeeded = process.terminationStatus == 0
            DispatchQueue.main.async {
                guard let self else { return }
                self.log += rest
                self.process = nil
                self.state = succeeded ? .idle : .failed(platform)
            }
        }

        log += "$ \(bridge.installCommand)\n"
        state = .installing(platform)
        do {
            try process.run()
            self.process = process
        } catch {
            output.readabilityHandler = nil
            log += "Could not run brew: \(error.localizedDescription)\n"
            state = .failed(platform)
        }
    }
}
