import Foundation

class ADBManager: ObservableObject {
    @Published var logOutput = ""

    private var task: Process?
    private var pipe: Pipe?

    init() {
        startADBServer()
    }

    func startADBServer() {
        let process = Process()
        process.launchPath = "/usr/bin/env"
        process.arguments = ["adb", "start-server"]
        process.launch()
        process.waitUntilExit()
    }

    func startLogcat() {
        pipe = Pipe()
        task = Process()
        task?.launchPath = "/usr/bin/env"
        task?.arguments = ["adb", "logcat"]
        task?.standardOutput = pipe
        task?.standardError = pipe

        let fileHandle = pipe!.fileHandleForReading
        task?.launch()

        DispatchQueue.global(qos: .background).async {
            let buffer = 4096
            while let output = try? fileHandle.read(upToCount: buffer), let str = String(data: output, encoding: .utf8) {
                DispatchQueue.main.async {
                    self.logOutput += str
                }
            }
        }
    }

    func stopLogcat() {
        task?.terminate()
        task = nil
    }
}
