import SwiftUI

/// The menu bar popover. Everyday use only: see projects, open them, add one.
/// Nothing here triggers a macOS permission prompt directly — setup and
/// uninstall live in their own windows, behind an explanation.
struct MenuPanel: View {
    @EnvironmentObject private var model: BeaconModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider().overlay(Color.beaconHairline)

            if let notice = model.notice {
                NoticeBanner(text: notice) { model.notice = nil }
            }

            if model.needsSetup && model.hasLoaded {
                SetupCard { AppWindows.open(WindowID.setup, with: openWindow) }
                    .padding(12)
                if model.isRunning { Divider().overlay(Color.beaconHairline) }
            } else if model.serviceOutdated {
                // The password prompt is introduced in Settings, like every other.
                ServiceUpdateCard {
                    model.settingsHighlight = .service
                    AppWindows.openSettings(with: openSettings)
                }
                    .padding(12)
                Divider().overlay(Color.beaconHairline)
            } else if model.showsAgentPrompt {
                AgentPromptCard()
                    .padding(12)
                Divider().overlay(Color.beaconHairline)
            }

            if model.isRunning {
                projectList
            }

            Divider().overlay(Color.beaconHairline)
            footer
        }
        .frame(width: 380)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            BeaconSymbol(size: 16)
            Text("Beacon")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.beaconText)
            Spacer()
            serviceStatus
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
    }

    @ViewBuilder
    private var serviceStatus: some View {
        switch model.activity {
        case .restarting:
            busy("Restarting…")
        case .installing:
            busy("Installing…")
        case .uninstalling:
            busy("Uninstalling…")
        default:
            if !model.hasLoaded {
                EmptyView()
            } else if !model.isRunning {
                StatusLabel(text: "Not running", tone: .idle)
            } else if !model.resolverActive {
                StatusLabel(text: "Resolver missing", tone: .attention)
            } else {
                StatusLabel(text: "Resolver active", tone: .online)
            }
        }
    }

    private func busy(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(text)
                .font(.beaconLabel)
                .foregroundStyle(Color.beaconSecondaryText)
        }
    }

    @ViewBuilder
    private var projectList: some View {
        if model.sites.isEmpty {
            VStack(spacing: 6) {
                Text("No projects yet")
                    .font(.beaconBodyEmphasis)
                    .foregroundStyle(Color.beaconText)
                HStack(spacing: 4) {
                    Text("Add one below, or run")
                    Text("beacon register").font(.beaconMono)
                    Text("in a project folder.")
                }
                .font(.beaconLabel)
                .foregroundStyle(Color.beaconSecondaryText)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.sites) { site in
                        ProjectRow(site: site)
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(maxHeight: 44 * 7 + 12)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            if model.isRunning {
                Button {
                    AppWindows.open(WindowID.addProject, with: openWindow)
                } label: {
                    Label("Add project", systemImage: "plus")
                }
                .buttonStyle(.signalCompact)
            }
            Spacer()
            Button("Settings…") { AppWindows.openSettings(with: openSettings) }
                .buttonStyle(.quiet)
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.quiet)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
    }
}

/// One project. Click to open it; the context menu has the rest. When it's
/// down and Beacon knows how to start it, a play button brings it up.
struct ProjectRow: View {
    @EnvironmentObject private var model: BeaconModel
    @Environment(\.openSettings) private var openSettings
    @State private var isHovering = false
    @State private var confirmingRemoval: Bool
    @State private var askingToShare: Bool
    @State private var password = ""
    let site: Site

    init(site: Site, confirmingRemoval: Bool = false, askingToShare: Bool = false) {
        self.site = site
        _confirmingRemoval = State(initialValue: confirmingRemoval)
        _askingToShare = State(initialValue: askingToShare)
    }

    private var shared: SharedProject? { model.shared(site) }

    private var run: RunStatus? { model.run(for: site) }
    private var isUp: Bool { model.isUp(site) }
    private var isStarting: Bool { run?.state == .starting }
    /// Started from the menu and still up, so it's ours to stop.
    private var isStoppable: Bool { isUp && run?.state == .running }

    var body: some View {
        if confirmingRemoval {
            removalConfirmation
        } else if askingToShare {
            shareForm
        } else {
            row
        }
    }

    private var row: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Text(site.domain)
                    .font(.beaconBodyEmphasis)
                    .foregroundStyle(Color.beaconText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if shared != nil { shareBadge }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(verbatim: "localhost:\(site.port)")
                .font(.beaconMono)
                .foregroundStyle(Color.beaconSecondaryText)

            status
                .frame(width: 72, alignment: .leading)

            action
                .frame(width: 20)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .overlay(alignment: .bottom) {
            if isStarting, let run { StartProgress(run: run).padding(.horizontal, 12) }
        }
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isHovering ? Color.beaconSelection : .clear)
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { model.open(site) }
        .help(helpText)
        .contextMenu {
            Button("Open in browser") { model.open(site) }
            if model.canStart(site) && !isUp && !isStarting {
                Button("Start project") { Task { await model.start(site) } }
            }
            if isUp {
                Button("Stop project") { Task { await model.stop(site) } }
            }
            if run != nil {
                Button("Show output") { model.showOutput(site) }
            }
            Divider()
            Button("Copy URL") { model.copy(site.url) }
            Button("Copy port") { model.copy(String(site.port)) }
            if site.path != nil {
                Button("Show in Finder") { model.revealInFinder(site) }
            }
            Divider()
            shareMenuItems
            Divider()
            Button("Remove project…", role: .destructive) { confirmingRemoval = true }
        }
    }

    // MARK: - Sharing

    @ViewBuilder
    private var shareMenuItems: some View {
        if let shared {
            if let url = shared.publicURL {
                Button("Open public URL") { model.openPublic(site) }
                Button("Copy public URL") { model.copy(url) }
            }
            Button("Stop sharing") { Task { await model.unshare(site) } }
        } else if model.relayConfigured {
            Button("Share on the internet…") { askingToShare = true }
        } else if model.daemonSupportsSharing {
            Button("Set up sharing…") { AppWindows.openSettings(with: openSettings) }
        }
    }

    /// Green once the relay has the URL live, amber while it hasn't.
    private var shareBadge: some View {
        let live = shared?.publicURL != nil && model.relay?.state == .connected
        return Image(systemName: "globe")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(live ? Color.beaconOnline : Color.beaconSignal)
    }

    /// The address the relay will give this project, when it can be known in
    /// advance: the label only arrives once the tunnel has connected.
    private var expectedAddress: String? {
        guard let relay = model.relay, let label = relay.label, let url = relay.url else { return nil }
        var host = url
        if let schemeEnd = host.range(of: "://") { host = String(host[schemeEnd.upperBound...]) }
        host = String(host.prefix { $0 != "/" && $0 != ":" })
        return "\(site.name)-\(label).\(host)"
    }

    /// Asked in the row, for the same reason as removal.
    private var shareForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Share \(site.domain) on the internet?")
                .font(.beaconBodyEmphasis)
                .foregroundStyle(Color.beaconText)
            Text("Anyone with the link reaches port \(String(site.port)) until you stop sharing it.")
                .font(.beaconLabel)
                .foregroundStyle(Color.beaconSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if let expectedAddress {
                Text(verbatim: "https://\(expectedAddress)")
                    .font(.beaconMono)
                    .foregroundStyle(Color.beaconText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            SecureField("Password (optional)", text: $password)
                .textFieldStyle(.roundedBorder)
                .font(.beaconLabel)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") {
                    askingToShare = false
                    password = ""
                }
                .buttonStyle(.quiet)
                .keyboardShortcut(.cancelAction)
                Button("Share") {
                    let chosen = password.isEmpty ? nil : password
                    askingToShare = false
                    password = ""
                    Task { await model.share(site, password: chosen) }
                }
                .buttonStyle(.signalCompact)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.beaconSelection.opacity(0.6))
        )
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    /// Asked inside the row rather than in a dialog. A dialog opens as its
    /// own window, and clicking it closes the menu bar panel underneath,
    /// leaving the dialog stranded on screen.
    private var removalConfirmation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Remove \(site.domain)?")
                .font(.beaconBodyEmphasis)
                .foregroundStyle(Color.beaconText)
            Text("Beacon stops routing it and releases port \(String(site.port)), which may be given to another project.")
                .font(.beaconLabel)
                .foregroundStyle(Color.beaconSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { confirmingRemoval = false }
                    .buttonStyle(.quiet)
                    .keyboardShortcut(.cancelAction)
                Button("Remove project") {
                    confirmingRemoval = false
                    Task { await model.remove(site) }
                }
                .buttonStyle(.destructiveCompact)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.beaconSelection.opacity(0.6))
        )
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var status: some View {
        if isStarting {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Starting")
                    .font(.beaconLabel)
                    .foregroundStyle(Color.beaconSecondaryText)
            }
        } else if isUp {
            StatusLabel(text: "Online", tone: .online)
        } else if run?.state == .failed {
            StatusLabel(text: "Failed", tone: .attention)
        } else {
            StatusLabel(text: "Offline", tone: .idle)
        }
    }

    /// Start when down, stop when the menu started it; nothing otherwise, so
    /// Beacon never offers to stop a dev server someone ran by hand.
    @ViewBuilder
    private var action: some View {
        if !isUp && !isStarting && model.canStart(site) {
            iconButton(run?.state == .failed ? "arrow.clockwise" : "play.fill") {
                Task { await model.start(site) }
            }
        } else if isStoppable && isHovering {
            iconButton("stop.fill") { Task { await model.stop(site) } }
        } else {
            // Holds the column, so every row's status lines up.
            Color.clear
        }
    }

    private func iconButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.quiet)
    }

    private var helpText: String {
        if let shared {
            if let url = shared.publicURL { return "\(baseHelpText)\nShared at \(url)" }
            if let error = shared.error { return "\(baseHelpText)\nNot shared: \(error)" }
            return "\(baseHelpText)\nWaiting for the relay to share it."
        }
        return baseHelpText
    }

    private var baseHelpText: String {
        if isStarting { return run?.log.last ?? "Starting \(site.name)…" }
        if run?.state == .failed { return run?.message ?? "\(site.name) didn't start." }
        if isUp { return "Open \(site.url)" }
        if model.canStart(site) {
            let command = site.runSpec?.command ?? "its run command"
            return "Nothing is listening on port \(site.port). Press ▶ to start it with `\(command)`."
        }
        return "Nothing is listening on port \(site.port). Start the project's dev server on that port."
    }
}

/// A hairline under a starting row that eases towards the expected start
/// time, the same curve as the browser page uses.
private struct StartProgress: View {
    let run: RunStatus

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { context in
            let started = run.startedAt ?? context.date
            let seconds = max(0, context.date.timeIntervalSince(started))
            let expected = max(run.expectedSeconds ?? 10, 1)
            let fraction = 0.95 * (1 - exp(-1.6 * seconds / expected))

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.beaconHairline)
                    Capsule().fill(Color.beaconSignal)
                        .frame(width: proxy.size.width * fraction)
                        .animation(.linear(duration: 0.2), value: fraction)
                }
            }
            .frame(height: 2)
        }
        .padding(.bottom, 4)
    }
}

/// Shown in the popover until both setup steps are done.
struct SetupCard: View {
    @EnvironmentObject private var model: BeaconModel
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Finish setting up Beacon")
                .font(.beaconBodyEmphasis)
                .foregroundStyle(Color.beaconText)

            VStack(alignment: .leading, spacing: 6) {
                step("Background service", done: model.isRunning)
                step("HTTPS certificate", done: model.caTrusted)
            }

            Button("Continue setup…", action: onContinue)
                .buttonStyle(.signalCompact)
                .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .beaconCard()
    }

    private func step(_ title: String, done: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12))
                .foregroundStyle(done ? Color.beaconOnline : Color.beaconSlate)
            Text(title)
                .font(.beaconLabel)
                .foregroundStyle(done ? Color.beaconSecondaryText : Color.beaconText)
        }
    }
}

/// Shown after Sparkle has updated the app while the old service still runs.
struct ServiceUpdateCard: View {
    @EnvironmentObject private var model: BeaconModel
    let onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Update the background service")
                .font(.beaconBodyEmphasis)
                .foregroundStyle(Color.beaconText)
            Text("Beacon is now \(BeaconPaths.version), but its service is still \(model.status?.version ?? "an older version"). Update it to get this version's fixes in the service.")
                .font(.beaconLabel)
                .foregroundStyle(Color.beaconSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Button("Update in Settings…", action: onContinue)
                .buttonStyle(.signalCompact)
                .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .beaconCard()
    }
}

/// Offers to tell Claude Code and Codex about Beacon, once Beacon is set up,
/// until the instructions are in or the user closes it.
struct AgentPromptCard: View {
    @EnvironmentObject private var model: BeaconModel

    private var added: Bool { !model.agentsJustAdded.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.beaconBodyEmphasis)
                    .foregroundStyle(Color.beaconText)
                Spacer(minLength: 4)
                Button { model.dismissAgentPrompt() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.quiet)
                .help(added ? "Close" : "Don't show this again. You can still add them in Settings.")
            }

            Text(detail)
                .font(.beaconLabel)
                .foregroundStyle(Color.beaconSecondaryText)
                .fixedSize(horizontal: false, vertical: true)

            if added {
                Button("Done") { model.dismissAgentPrompt() }
                    .buttonStyle(.signalCompact)
                    .padding(.top, 2)
            } else {
                Button("Add to \(list(model.agentsMissingInstructions.map(\.name)))") {
                    Task { await model.addAgentInstructions() }
                }
                .buttonStyle(.signalCompact)
                .help("The same as running beacon agent-guide --global")
                .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .beaconCard()
    }

    private var title: String {
        guard added else { return "Tell your coding agents about Beacon" }
        let names = model.agentsJustAdded
        return "\(list(names)) \(names.count == 1 ? "knows" : "know") about Beacon"
    }

    private var detail: String {
        guard added else {
            let names = list(model.agentsMissingInstructions.map(\.name))
            return "Beacon can add a short note to \(names) so they ask it for a port and give you .\(model.config.primaryTLD) links instead of localhost ones."
        }
        let files = model.agents
            .filter { model.agentsJustAdded.contains($0.name) }
            .map { ($0.file as NSString).abbreviatingWithTildeInPath }
        return "New sessions will ask Beacon for a port. The note is in \(list(files)) if you want to change or remove it."
    }

    private func list(_ items: [String]) -> String {
        ListFormatter.localizedString(byJoining: items)
    }
}

struct NoticeBanner: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.beaconSignal)
            Text(text)
                .font(.beaconLabel)
                .foregroundStyle(Color.beaconText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.quiet)
            .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.beaconSelection.opacity(0.6))
    }
}
