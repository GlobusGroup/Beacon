import Foundation

/// Carries running projects across a restart of the daemon: an update,
/// `beacon install` or `beacon restart`.
///
/// A daemon from Beacon 1.6.0 or earlier was the only reader of its projects'
/// output, through a pipe. When it exits, the dev servers it started keep
/// running but can no longer write, and many (Python's http.server among
/// them) then drop every request while still listening. Daemons since take
/// their projects back on startup, so this only acts on what the new daemon
/// couldn't take back: it restarts those, so they come up under the new one.
///
/// Usage: `capture` before restarting the daemon, `restore` once it answers.
public struct ProjectHandover: Sendable {
    /// Projects the outgoing daemon started and that were running.
    public let names: [String]

    /// Projects the outgoing daemon started and that are running now.
    /// Detached projects (containers) are left out: their command has already
    /// exited, so they never depended on the daemon, and the listener on
    /// their port is Docker's, which a restart must not touch.
    public static func capture(_ client: BeaconClient) -> ProjectHandover {
        let sites = (try? client.list()) ?? []
        let names = sites.compactMap { site -> String? in
            guard let spec = site.runSpec, !spec.detached,
                  let run = try? client.runStatus(name: site.name),
                  run.state == .running,
                  // Only a project the daemon started has a start time; one
                  // started by hand is just a port that answers.
                  run.startedAt != nil
            else { return nil }
            return site.name
        }
        return ProjectHandover(names: names)
    }

    /// Restarts each captured project the new daemon didn't take back.
    /// Returns the ones it restarted. Doesn't wait for them to come up.
    @discardableResult
    public func restore(_ client: BeaconClient) -> [String] {
        names.filter { name in
            guard let run = try? client.runStatus(name: name),
                  run.state == .running, run.startedAt == nil
            else { return false }
            return (try? client.restartProject(name: name)) != nil
        }
    }
}
