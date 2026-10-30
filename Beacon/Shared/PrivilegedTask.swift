import Foundation
import Security

/// Runs a shell script as root behind the system authorisation dialog — the
/// same one the padlock in System Settings uses, which accepts Touch ID.
///
/// AppleScript's `do shell script … with administrator privileges` is the
/// obvious way to do this and the reason not to: it draws a legacy name and
/// password panel with no biometric support. Going through Authorization
/// Services directly gets the modern prompt.
///
/// Whether the prompt offers Touch ID or only a password depends on the
/// *caller's* code signature: SecurityAgent gives an ad-hoc or unsigned binary
/// the legacy password panel. The SwiftPM-built `beacon` CLI is ad-hoc signed,
/// so it gets passwords; the app, signed with a Developer ID, gets biometrics.
/// That asymmetry is expected, not a bug to chase.
///
/// `AuthorizationExecuteWithPrivileges` is deprecated. Apple's replacement is a
/// bundled, code-signed helper installed via `SMAppService`, which for Beacon
/// would mean moving the daemon inside the app bundle and sending the user to
/// System Settings to approve it. The deprecated call still ships and still
/// works, and this runs once at install time, so it stays — reached through
/// `dlsym` so its deprecation doesn't leak into every build.
public enum PrivilegedTask {
    /// Marks the end of the script's output so the exit status survives a
    /// channel that only hands back a pipe.
    private static let sentinel = "__BEACON_EXIT__:"

    /// Dismissing the prompt and the API being missing are different things,
    /// and the caller must not retry on the first.
    public enum Outcome {
        case completed(ShellResult)
        case cancelled
        case unavailable
    }

    public static var isAvailable: Bool { executeWithPrivileges != nil }

    public static func run(script: String, prompt: String) -> Outcome {
        guard let execute = executeWithPrivileges else { return .unavailable }

        var authorization: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &authorization) == errAuthorizationSuccess,
              let authorization else {
            return .unavailable
        }
        defer { AuthorizationFree(authorization, [.destroyRights]) }

        switch copyExecuteRight(authorization, prompt: prompt) {
        case errAuthorizationSuccess:
            break
        case errAuthorizationCanceled:
            return .cancelled
        case errAuthorizationInteractionNotAllowed:
            // No session to draw a dialog in. Let the caller try another way
            // rather than telling the user they cancelled something they
            // never saw.
            return .unavailable
        case let status:
            return .completed(ShellResult(
                status: Int32(status), stdout: "",
                stderr: "Authorisation failed (OSStatus \(status))."
            ))
        }

        let wrapped = "\(script); echo \"\(sentinel)$?\""
        var pipe: UnsafeMutablePointer<FILE>?

        let status = withCStrings(["-c", wrapped]) { argv in
            "/bin/sh".withCString { tool in
                execute(authorization, tool, [], argv, &pipe)
            }
        }

        guard status == errAuthorizationSuccess else {
            return .completed(ShellResult(
                status: Int32(status), stdout: "",
                stderr: "The system refused to run the command (\(status))."
            ))
        }

        let output = pipe.map(readToEnd) ?? ""
        return .completed(split(output))
    }

    // MARK: -

    private static func copyExecuteRight(_ authorization: AuthorizationRef, prompt: String) -> OSStatus {
        var name = Array(kAuthorizationRightExecute.utf8CString)
        return name.withUnsafeMutableBufferPointer { nameBuffer -> OSStatus in
            var item = AuthorizationItem(
                name: nameBuffer.baseAddress!,
                valueLength: 0, value: nil, flags: 0
            )
            return withUnsafeMutablePointer(to: &item) { itemPointer in
                var rights = AuthorizationRights(count: 1, items: itemPointer)
                return withPromptEnvironment(prompt) { environment in
                    AuthorizationCopyRights(
                        authorization,
                        &rights,
                        environment,
                        [.interactionAllowed, .preAuthorize, .extendRights],
                        nil
                    )
                }
            }
        }
    }

    /// The sentence shown above the password field and the Touch ID button.
    private static func withPromptEnvironment<T>(
        _ prompt: String,
        _ body: (UnsafePointer<AuthorizationEnvironment>?) -> T
    ) -> T {
        var promptName = Array(kAuthorizationEnvironmentPrompt.utf8CString)
        var promptValue = Array(prompt.utf8CString)

        return promptName.withUnsafeMutableBufferPointer { nameBuffer in
            promptValue.withUnsafeMutableBufferPointer { valueBuffer in
                var item = AuthorizationItem(
                    name: nameBuffer.baseAddress!,
                    // The trailing NUL isn't part of the value.
                    valueLength: valueBuffer.count - 1,
                    value: UnsafeMutableRawPointer(valueBuffer.baseAddress!),
                    flags: 0
                )
                return withUnsafeMutablePointer(to: &item) { itemPointer in
                    var environment = AuthorizationEnvironment(count: 1, items: itemPointer)
                    return body(&environment)
                }
            }
        }
    }

    private typealias ExecuteWithPrivileges = @convention(c) (
        AuthorizationRef,
        UnsafePointer<CChar>,
        AuthorizationFlags,
        UnsafePointer<UnsafeMutablePointer<CChar>?>,
        UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>?
    ) -> OSStatus

    private static let executeWithPrivileges: ExecuteWithPrivileges? = {
        guard let handle = dlopen(
            "/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY
        ) else { return nil }
        guard let symbol = dlsym(handle, "AuthorizationExecuteWithPrivileges") else { return nil }
        return unsafeBitCast(symbol, to: ExecuteWithPrivileges.self)
    }()

    private static func withCStrings<T>(
        _ arguments: [String],
        _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> T
    ) -> T {
        var pointers: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        pointers.append(nil)
        defer { pointers.forEach { $0.map { free($0) } } }
        return body(&pointers)
    }

    private static func readToEnd(_ file: UnsafeMutablePointer<FILE>) -> String {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let read = fread(&buffer, 1, buffer.count, file)
            if read <= 0 { break }
            data.append(contentsOf: buffer[0..<read])
        }
        fclose(file)
        return String(decoding: data, as: UTF8.self)
    }

    /// Peels the exit status back off the output.
    private static func split(_ output: String) -> ShellResult {
        guard let range = output.range(of: sentinel, options: .backwards) else {
            return ShellResult(status: 0, stdout: output, stderr: "")
        }
        let code = Int32(
            output[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        ) ?? 0
        let body = String(output[..<range.lowerBound])
        return ShellResult(
            status: code,
            stdout: code == 0 ? body : "",
            stderr: code == 0 ? "" : body
        )
    }
}
