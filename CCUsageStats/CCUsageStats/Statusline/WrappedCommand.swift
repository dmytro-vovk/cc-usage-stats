import Foundation

enum WrappedCommand {
    /// Runs `/bin/sh -c command`. Always returns the captured stdout (possibly empty).
    /// Never throws; never propagates errors.
    static func run(command: String, stdin: Data, timeout: TimeInterval) -> String {
        guard !command.isEmpty else { return "" }

        let process = Process()
        process.launchPath = "/bin/sh"
        process.arguments = ["-c", command]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = Pipe() // discard

        do { try process.run() } catch {
            return ""
        }

        // Feed stdin then close.
        try? stdinPipe.fileHandleForWriting.write(contentsOf: stdin)
        try? stdinPipe.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(timeout)
        var captured = Data()
        let readHandle = stdoutPipe.fileHandleForReading

        while process.isRunning && Date() < deadline {
            let chunk = readHandle.availableData
            if !chunk.isEmpty { captured.append(chunk) }
            else { Thread.sleep(forTimeInterval: 0.01) }
        }

        if process.isRunning {
            process.terminate()
            // Brief grace period.
            let grace = Date().addingTimeInterval(0.2)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.01) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }

        // Drain anything remaining.
        let rest = readHandle.readDataToEndOfFile()
        if !rest.isEmpty { captured.append(rest) }

        return String(data: captured, encoding: .utf8) ?? ""
    }
}
