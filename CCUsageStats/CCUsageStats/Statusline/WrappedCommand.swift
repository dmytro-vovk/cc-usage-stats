import Foundation

enum WrappedCommand {
    /// Runs `/bin/sh -c command`. Always returns captured stdout. Never throws.
    static func run(command: String, stdin: Data, timeout: TimeInterval) -> String {
        guard !command.isEmpty else { return "" }

        let process = Process()
        process.launchPath = "/bin/sh"
        process.arguments = ["-c", command]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()

        var captured = Data()
        let lock = NSLock()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            lock.lock(); captured.append(chunk); lock.unlock()
        }

        do { try process.run() } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            return ""
        }

        try? stdinPipe.fileHandleForWriting.write(contentsOf: stdin)
        try? stdinPipe.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }

        if process.isRunning {
            process.terminate()
            let grace = Date().addingTimeInterval(0.2)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }

        // Allow any final pending readability events to flush, then detach.
        Thread.sleep(forTimeInterval: 0.05)
        stdoutPipe.fileHandleForReading.readabilityHandler = nil

        lock.lock()
        defer { lock.unlock() }
        return String(data: captured, encoding: .utf8) ?? ""
    }
}
