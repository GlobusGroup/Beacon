import BeaconKit
import Foundation

/// Starts projects on request and watches them come up.
///
/// The daemon is root, but a project must never run as root: files it writes
/// would end up root-owned in someone's checkout, and `node`, `docker` and
/// friends live on that person's `PATH`, not root's. So each command runs as
/// whoever owns the project directory, through a login shell, inside their
/// launchd session — the same environment as a terminal they opened.
///
/// "Up" means something accepts connections on the project's port. That is
/// the only signal that holds for every kind of project, and it's exactly the
/// condition the proxy needs.
final class ProjectRunner: @unchecked Sendable {
    private final class Job {
        let spec: RunSpec
        let port: Int
        let process: Process
        let startedAt = Date()
        var endedAt: Date?
        var state: RunStatus.State = .starting
        var phase: String
        var message: String?
        var lines: [String] = []
        /// Output after the last newline, waiting for the rest of its line.
        var partial = ""
        /// The log file, open for appending. The project writes to it
        /// directly; the daemon only uses this for a stop command's output.
        var logHandle: FileHandle?
        /// Follows the log file to fill `lines`.
        var logWatcher: DispatchSourceFileSystemObject?
        var exited = false

        init(spec: RunSpec, port: Int, process: Process, phase: String) {
            self.spec = spec
            self.port = port
            self.process = process
            self.phase = phase
        }

        deinit { logWatcher?.cancel() }
    }

    /// How long a start may take before Beacon calls it a failure.
    static let startTimeout: TimeInterval = 300
    static let keptLines = 200

    private let lock = NSLock()
    private var jobs: [String: Job] = [:]
    private var startTimes: [String: Double] = [:]
    private let queue = DispatchQueue(label: "io.beacon.runner")

    init() {
        if let data = FileManager.default.contents(atPath: BeaconPaths.startTimesFile),
           let decoded = try? JSONDecoder().decode([String: Double].self, from: data) {
            startTimes = decoded
        }
    }

    // MARK: - Requests

    func status(for site: Site) -> RunStatus {
        lock.lock()
        defer { lock.unlock() }
        if let job = jobs[site.name], job.port == site.port, !job.exited || job.spec == site.runSpec {
            refreshLocked(name: site.name, job: job)
            return makeStatusLocked(name: site.name, job: job)
        }
        // No attempt yet, or the last one finished under a command that has
        // since changed: report the project as it stands now.
        let spec = site.runSpec
        return RunStatus(
            name: site.name,
            state: Self.isAccepting(site.port) ? .running : .stopped,
            command: spec?.command,
            label: spec?.label,
            expectedSeconds: spec.map { startTimes[Self.timingKey(site.name, $0)] ?? $0.expectedSeconds }
        )
    }

    /// Idempotent: asking again while a start is under way returns its
    /// progress rather than launching a second copy.
    func start(_ site: Site) throws -> RunStatus {
        guard let path = site.path, FileManager.default.fileExists(atPath: path) else {
            throw BeaconClientError(
                code: "no_path",
                message: "Beacon doesn't know where '\(site.name)' lives. Re-register it from the project directory."
            )
        }
        guard let spec = site.runSpec else {
            throw BeaconClientError(
                code: "no_run_command",
                message: """
                Beacon can't tell how to start '\(site.name)'. Tell it with \
                `beacon register \(site.name) --run "<command>"`.
                """
            )
        }

        lock.lock()
        defer { lock.unlock() }

        if Self.isAccepting(site.port) {
            if let job = jobs[site.name] { refreshLocked(name: site.name, job: job) }
            return status(name: site.name, site: site)
        }
        if let job = jobs[site.name], job.state == .starting, !job.exited {
            return makeStatusLocked(name: site.name, job: job)
        }
        // A failed or stopped attempt may have left processes behind.
        if let old = jobs.removeValue(forKey: site.name), !old.exited {
            Self.terminateTree(old.process.processIdentifier)
        }

        let job = try launchLocked(site: site, path: path, spec: spec)
        jobs[site.name] = job
        Log.info("Starting \(site.name): \(spec.command)")
        scheduleCheck(name: site.name, job: job)
        return makeStatusLocked(name: site.name, job: job)
    }

    func stop(_ site: Site) -> RunStatus {
        lock.lock()
        let job = jobs[site.name]
        if let job {
            job.state = .stopped
            job.phase = "Stopped"
            job.endedAt = Date()
            if !job.exited { Self.terminateTree(job.process.processIdentifier) }
        }
        lock.unlock()

        // Detached projects (containers) outlive the command that started
        // them, and may have been started by hand, so stop them either way.
        if let stop = site.runSpec?.stopCommand, let path = site.path {
            queue.async {
                let process = Self.makeProcess(command: stop, path: path, site: site)
                process.standardOutput = job?.logHandle ?? FileHandle.nullDevice
                process.standardError = job?.logHandle ?? FileHandle.nullDevice
                try? process.run()
                process.waitUntilExit()
            }
        }
        Log.info("Stopping \(site.name).")
        return status(for: site)
    }

    // MARK: - Launching

    private func launchLocked(site: Site, path: String, spec: RunSpec) throws -> Job {
        let process = Self.makeProcess(command: spec.command, path: path, site: site)
        let job = Job(spec: spec, port: site.port, process: process, phase: "Running \(spec.command)")

        // The project writes straight to its log file rather than through a
        // pipe the daemon reads. A pipe's read end belongs to this process, so
        // restarting the daemon (an update does) used to break it under a dev
        // server that kept running: every later write failed, and a server
        // that logs each request before replying (Python's http.server)
        // dropped every request while still listening. A file has no reader
        // to lose.
        let logPath = BeaconPaths.projectLog(for: site.name)
        try? FileManager.default.createDirectory(
            atPath: BeaconPaths.projectLogsDir, withIntermediateDirectories: true
        )
        Self.rotateLog(at: logPath)
        let output = try Self.openLog(at: logPath)
        job.logHandle = output
        job.logWatcher = followLog(at: logPath, job: job)

        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output

        process.terminationHandler = { [weak self, weak job] process in
            guard let self, let job else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            job.exited = true
            let code = process.terminationStatus
            switch job.state {
            case .starting:
                if Self.isAccepting(job.port) {
                    self.markRunningLocked(name: site.name, job: job)
                } else if code == 0 {
                    // A clean exit before the port answers is how detached
                    // commands (`docker compose up -d`, a script that
                    // backgrounds a server) say they're done. Keep waiting;
                    // the timeout catches one that never comes up.
                    job.phase = job.spec.detached
                        ? "Containers are up — waiting for port \(job.port)"
                        : "Waiting for port \(job.port)"
                } else {
                    job.state = .failed
                    job.endedAt = Date()
                    job.phase = "Exited with status \(code)"
                    job.message = "`\(job.spec.command)` exited with status \(code) before anything listened on port \(job.port)."
                    Log.warn("\(site.name): \(job.message!)")
                }
            case .running where !Self.isAccepting(job.port):
                job.state = .stopped
                job.endedAt = Date()
                job.phase = "Exited with status \(code)"
            default:
                break
            }
        }

        do {
            try process.run()
        } catch {
            throw BeaconClientError(
                code: "launch_failed",
                message: "Couldn't run `\(spec.command)`: \(error.localizedDescription)"
            )
        }
        return job
    }

    /// Keeps the previous run's output as `<name>.log.1` instead of
    /// overwriting it: when a project misbehaves, the run before the restart
    /// is usually the one worth reading.
    private static func rotateLog(at path: String) {
        var info = stat()
        guard stat(path, &info) == 0, info.st_size > 0 else { return }
        if rename(path, path + ".1") != 0 {
            Log.warn("Couldn't keep the previous log \(path): \(String(cString: strerror(errno)))")
        }
    }

    /// Opens (creating if needed) the log for appending. `O_APPEND` keeps
    /// writes from the project and from a stop command from overwriting each
    /// other. Close-on-exec keeps it out of unrelated children; the project
    /// still gets it, as the copies on its stdout and stderr.
    private static func openLog(at path: String) throws -> FileHandle {
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw BeaconClientError(
                code: "launch_failed",
                message: "Couldn't open the log file \(path): \(String(cString: strerror(errno)))"
            )
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// Reads what the project appends to its log, for the progress page and
    /// `beacon status`. Runs until the job is replaced or dropped.
    private func followLog(at path: String, job: Job) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            Log.warn("Couldn't follow \(path): \(String(cString: strerror(errno)))")
            return nil
        }
        let reader = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend], queue: queue
        )
        source.setEventHandler { [weak self, weak job] in
            guard let self, let job else { return }
            guard let data = try? reader.readToEnd(), !data.isEmpty else { return }
            self.lock.lock()
            Self.append(data, to: job)
            self.lock.unlock()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    /// The command, wrapped so it runs as the project's owner in a login
    /// shell with `PORT` set.
    private static func makeProcess(command: String, path: String, site: Site) -> Process {
        let script = "cd \(shellQuote(path)) && \(command)"
        let environment = [
            "PORT=\(site.port)",
            "BEACON_PORT=\(site.port)",
            "BEACON_URL=\(site.url)",
            "BEACON_DOMAIN=\(site.domain)",
        ]
        let process = Process()
        var info = stat()

        if getuid() == 0, stat(path, &info) == 0, info.st_uid != 0, let owner = getpwuid(info.st_uid) {
            let shell = String(cString: owner.pointee.pw_shell)
            // `asuser` puts the command in the owner's launchd session, so it
            // can reach their keychain (Docker's credential helper needs it).
            // sudo then drops to their uid and gives them their own $HOME.
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["asuser", String(info.st_uid), "/usr/bin/sudo", "-u", "#\(info.st_uid)", "-H", "--",
                                 "/usr/bin/env"] + environment + [shell.isEmpty ? "/bin/zsh" : shell, "-l", "-i", "-c", script]
        } else {
            // Not root (`make dev`), or a root-owned directory: run as ourselves.
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            process.executableURL = URL(fileURLWithPath: shell)
            process.arguments = ["-l", "-i", "-c", script]
            var env = ProcessInfo.processInfo.environment
            for pair in environment {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                env[parts[0]] = parts[1]
            }
            process.environment = env
        }
        return process
    }

    // MARK: - Watching

    private func scheduleCheck(name: String, job: Job) {
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self, weak job] in
            guard let self, let job else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            // A newer attempt replaced this one.
            guard self.jobs[name] === job, job.state == .starting else { return }
            self.refreshLocked(name: name, job: job)
            if job.state == .starting { self.scheduleCheck(name: name, job: job) }
        }
    }

    private func refreshLocked(name: String, job: Job) {
        switch job.state {
        case .starting:
            if Self.isAccepting(job.port) {
                markRunningLocked(name: name, job: job)
            } else if Date().timeIntervalSince(job.startedAt) > Self.startTimeout {
                job.state = .failed
                job.endedAt = Date()
                job.phase = "Timed out"
                job.message = """
                Nothing listened on port \(job.port) after \(Int(Self.startTimeout / 60)) minutes. \
                If the dev server came up on another port, make it use $PORT (\(job.port)).
                """
                Log.warn("\(name): start timed out.")
            }
        case .running:
            if job.exited && !Self.isAccepting(job.port) {
                job.state = .stopped
                job.phase = "Stopped"
            }
        case .failed, .stopped:
            // It may have come up after all, or been started by hand.
            if Self.isAccepting(job.port) { job.state = .running; job.message = nil }
        }
    }

    private func markRunningLocked(name: String, job: Job) {
        job.state = .running
        job.endedAt = Date()
        job.phase = "Listening on port \(job.port)"
        job.message = nil
        let took = Date().timeIntervalSince(job.startedAt)
        startTimes[Self.timingKey(name, job.spec)] = took
        if let data = try? JSONEncoder().encode(startTimes) {
            try? data.write(to: URL(fileURLWithPath: BeaconPaths.startTimesFile), options: .atomic)
        }
        Log.info("\(name) is up after \(String(format: "%.1f", took))s.")
    }

    // MARK: - Reporting

    private func status(name: String, site: Site) -> RunStatus {
        if let job = jobs[name] { return makeStatusLocked(name: name, job: job) }
        let spec = site.runSpec
        return RunStatus(
            name: name, state: Self.isAccepting(site.port) ? .running : .stopped,
            command: spec?.command, label: spec?.label
        )
    }

    private func makeStatusLocked(name: String, job: Job) -> RunStatus {
        RunStatus(
            name: name,
            state: job.state,
            command: job.spec.command,
            label: job.spec.label,
            phase: job.phase,
            message: job.message,
            startedAt: job.startedAt,
            elapsed: (job.endedAt ?? Date()).timeIntervalSince(job.startedAt),
            expectedSeconds: startTimes[Self.timingKey(name, job.spec)] ?? job.spec.expectedSeconds,
            log: Array(job.lines.suffix(40)),
            logFile: BeaconPaths.projectLog(for: name)
        )
    }

    /// Splits output into display lines: colour codes stripped, and for
    /// carriage-return progress bars only the latest redraw kept.
    private static func append(_ data: Data, to job: Job) {
        let text = job.partial + String(decoding: data, as: UTF8.self)
        var pieces = text.components(separatedBy: "\n")
        job.partial = pieces.removeLast()
        for piece in pieces {
            let line = clean(piece)
            if !line.isEmpty { job.lines.append(line) }
        }
        if job.lines.count > keptLines { job.lines.removeFirst(job.lines.count - keptLines) }
    }

    private static func clean(_ raw: String) -> String {
        let latest = raw.components(separatedBy: "\r").last(where: { !$0.isEmpty }) ?? ""
        return latest
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Helpers

    /// Connects rather than binds. Binding to test a port — what `PortProbe`
    /// does — would, during a start, race the dev server for the very port it
    /// is trying to open.
    static func isAccepting(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// Signals a process and everything under it. Shells, sudo and package
    /// managers each add a layer, and the dev server is at the bottom.
    static func terminateTree(_ pid: Int32) {
        var all: [Int32] = []
        var frontier = [pid]
        while let next = frontier.popLast() {
            all.append(next)
            let children = Shell.run("/usr/bin/pgrep", ["-P", String(next)]).stdout
                .split(separator: "\n").compactMap { Int32($0) }
            frontier += children
        }
        for target in all.reversed() { kill(target, SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            for target in all where kill(target, 0) == 0 { kill(target, SIGKILL) }
        }
    }

    /// Start times are per command: switching a project from Node to Docker
    /// shouldn't keep promising the old timing.
    private static func timingKey(_ name: String, _ spec: RunSpec) -> String {
        name + " " + spec.command
    }

    private static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
