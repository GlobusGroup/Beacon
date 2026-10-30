import Foundation

public struct ShellResult: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var succeeded: Bool { status == 0 }
    /// The user dismissed a system prompt. That's a choice, not an error, and
    /// should never be reported as one.
    public var wasCancelled: Bool {
        let text = (stdout + stderr).lowercased()
        return text.contains("user canceled") || text.contains("canceled by the user")
            || text.contains("cancelled by the user")
    }
    /// stderr when there is any, otherwise stdout — whichever actually explains the failure.
    public var message: String {
        let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return err.isEmpty ? stdout.trimmingCharacters(in: .whitespacesAndNewlines) : err
    }
}

public enum Shell {
    @discardableResult
    public static func run(_ launchPath: String, _ arguments: [String]) -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do {
            try process.run()
        } catch {
            return ShellResult(status: -1, stdout: "", stderr: error.localizedDescription)
        }

        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return ShellResult(
            status: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }

    /// Runs a shell script as root.
    ///
    /// Prefers the system authorisation dialog, which supports Touch ID. Falls
    /// back to AppleScript's name-and-password panel only if Authorization
    /// Services isn't reachable — never after the user has dismissed a prompt,
    /// which would just ask them twice.
    public static func runAsAdmin(script: String, prompt: String) -> ShellResult {
        switch PrivilegedTask.run(script: script, prompt: prompt) {
        case .completed(let result):
            return result
        case .cancelled:
            return ShellResult(status: 1, stdout: "", stderr: "User canceled.")
        case .unavailable:
            return runAsAdminViaAppleScript(script: script, prompt: prompt)
        }
    }

    private static func runAsAdminViaAppleScript(script: String, prompt: String) -> ShellResult {
        let escaped = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let promptEscaped = prompt.replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(escaped)\" with prompt \"\(promptEscaped)\" with administrator privileges"
        return run("/usr/bin/osascript", ["-e", appleScript])
    }
}
