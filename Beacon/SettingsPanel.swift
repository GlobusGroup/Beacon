import SwiftUI
import UniformTypeIdentifiers

/// The sidebar entries in Settings.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general, sharing, access, agents, service, updates

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .sharing: "Sharing"
        case .access: "Relay access"
        case .agents: "Coding agents"
        case .service: "Service"
        case .updates: "Updates"
        }
    }

    var symbol: String {
        switch self {
        case .general: "globe"
        case .sharing: "antenna.radiowaves.left.and.right"
        case .access: "person.2"
        case .agents: "sparkles"
        case .service: "gearshape.2"
        case .updates: "arrow.down.circle"
        }
    }
}

extension SettingsHighlight {
    var pane: SettingsPane {
        switch self {
        case .service: .service
        case .sharing: .sharing
        }
    }
}

struct SettingsPanel: View {
    @EnvironmentObject private var model: BeaconModel
    @ObservedObject private var updater = AppUpdater.shared
    @Environment(\.openWindow) private var openWindow

    @State private var tlds = ""
    @State private var rangeStart = 3100
    @State private var rangeEnd = 3999
    @State private var defaultSecure = true
    @State private var loaded = false
    @State private var saveError: String?

    @State private var relayURL = ""
    @State private var relayToken = ""
    @State private var relayLoaded = false
    @State private var relayError: String?
    @State private var importingInvite = false

    @State private var pane: SettingsPane? = .general

    @State private var explaining: PrivilegedAction?
    @State private var outcome: (action: PrivilegedAction, result: ActionOutcome)?

    init() {}

    #if DEBUG
    /// Opens on a given pane, for snapshots.
    init(pane: SettingsPane) {
        _pane = State(initialValue: pane)
    }
    #endif

    /// Relay access only appears for an admin token.
    private var panes: [SettingsPane] {
        SettingsPane.allCases.filter { $0 != .access || model.relayTokens != nil }
    }

    private var current: SettingsPane {
        guard let pane, panes.contains(pane) else { return .general }
        return pane
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            ScrollViewReader { proxy in
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onChange(of: model.settingsHighlight, initial: true) { _, target in
                        reveal(target, with: proxy)
                    }
            }
        }
        .frame(width: 720, height: 520)
        .navigationTitle(current.title)
        .onAppear {
            load()
            loadRelay()
            AppWindows.becomeRegularApp()
        }
        .onChange(of: model.config) { _, _ in if !isDirty { load(force: true) } }
        .onChange(of: model.relay?.url) { _, _ in if !relayDirty { loadRelay(force: true) } }
        .onChange(of: model.pendingInvite, initial: true) { _, pending in
            guard let pending else { return }
            relayURL = pending.invite.relay
            relayToken = pending.invite.token
            relayLoaded = true
            relayError = nil
        }
        .task { await model.loadRelayTokens() }
        .sheet(item: $explaining) { action in
            PermissionExplainer(action: action) { purge in run(action, purge: purge) }
        }
        .fileImporter(isPresented: $importingInvite, allowedContentTypes: [.beaconInvite]) { result in
            if case .success(let url) = result { model.openInvite(url) }
        }
    }

    // MARK: - Layout

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(panes) { pane in
                Button { self.pane = pane } label: { sidebarRow(pane) }
                    .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(10)
        .frame(width: 190)
        .frame(maxHeight: .infinity)
        .background(Color.beaconHairline.opacity(0.35))
    }

    private func sidebarRow(_ pane: SettingsPane) -> some View {
        HStack(spacing: 8) {
            Image(systemName: pane.symbol)
                .frame(width: 18)
                .foregroundStyle(Color.beaconSecondaryText)
            Text(pane.title)
                .font(.beaconBody)
                .foregroundStyle(Color.beaconText)
            Spacer()
            if needsAttention(pane) {
                Circle().fill(Color.beaconSignal).frame(width: 7, height: 7)
                    .accessibilityLabel("Needs attention")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(current == pane ? Color.beaconSelection : Color.clear)
        )
        .contentShape(Rectangle())
        .accessibilityAddTraits(current == pane ? .isSelected : [])
    }

    @ViewBuilder
    private var detail: some View {
        switch current {
        case .access:
            RelayAccessView()
                .environmentObject(model)
        default:
            Form {
                switch current {
                case .general: routingSection
                case .sharing: sharingSection
                case .agents: agentsSection
                case .service:
                    serviceSection
                    uninstallSection
                case .updates: updatesSection
                case .access: EmptyView()
                }
            }
            .formStyle(.grouped)
        }
    }

    /// Marks a pane in the sidebar when something in it wants doing.
    private func needsAttention(_ pane: SettingsPane) -> Bool {
        switch pane {
        case .service: model.serviceOutdated || (model.isRunning && !model.caTrusted)
        case .sharing: model.relay?.state == .failed || model.pendingInvite != nil
        default: false
        }
    }

    // MARK: - Routing

    private var routingSection: some View {
        Section {
            LabeledContent("Domains") {
                TextField("", text: $tlds, prompt: Text("test"))
                    .font(.beaconMono)
                    .multilineTextAlignment(.trailing)
            }
            LabeledContent("Port range") {
                HStack(spacing: 8) {
                    portField($rangeStart)
                    Text("to")
                        .font(.beaconLabel)
                        .foregroundStyle(Color.beaconSecondaryText)
                    portField($rangeEnd)
                }
            }
            LabeledContent("New projects use") {
                Picker("", selection: $defaultSecure) {
                    Text("https://").tag(true)
                    Text("http://").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }

            HStack {
                if let saveError {
                    Label(saveError, systemImage: "exclamationmark.triangle.fill")
                        .font(.beaconLabel)
                        .foregroundStyle(.red)
                } else {
                    Text("TLDs are space-separated with the dot omitted.")
                        .font(.beaconLabel)
                        .foregroundStyle(Color.beaconSecondaryText)
                }
                Spacer()
                Button("Apply") { apply() }
                    .buttonStyle(.signalCompact)
                    .disabled(!isDirty || !model.isRunning || model.activity == .saving)
            }
        } header: {
            Text("Routing")
        }
    }

    // MARK: - Sharing

    private var sharingSection: some View {
        Section {
            if model.isRunning && !model.daemonSupportsSharing {
                Text("The background service is older than this app and can't share projects. Update it in Service.")
                    .font(.beaconLabel)
                    .foregroundStyle(Color.beaconSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LabeledContent("Address") {
                    TextField("", text: $relayURL, prompt: Text("relay.example.com"))
                        .font(.beaconMono)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Token") {
                    SecureField("", text: $relayToken, prompt: Text(model.relay?.hasToken == true ? "Saved · paste to replace" : "Paste your token"))
                        .font(.beaconMono)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Tunnel") { tunnelStatus }

                if let pending = model.pendingInvite {
                    HStack(alignment: .firstTextBaseline) {
                        Label("Filled in from \(pending.fileName), for \(pending.invite.label). Apply to start using it.", systemImage: "doc.badge.arrow.up")
                            .font(.beaconLabel)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Discard") {
                            model.pendingInvite = nil
                            relayToken = ""
                            loadRelay(force: true)
                        }
                        .controlSize(.small)
                    }
                    .background { highlight(.sharing) }
                    .id(SettingsHighlight.sharing)
                }

                HStack {
                    if let relayError {
                        Label(relayError, systemImage: "exclamationmark.triangle.fill")
                            .font(.beaconLabel)
                            .foregroundStyle(.red)
                    } else {
                        Text("Share a project from its menu to give it a public URL.")
                            .font(.beaconLabel)
                            .foregroundStyle(Color.beaconSecondaryText)
                    }
                    Spacer()
                    Button("Open .beacon…") { importingInvite = true }
                        .help("Fill in the relay from a .beacon file an admin sent you.")
                    if model.relayConfigured {
                        Button("Turn off") { applyRelay(url: "", token: "") }
                            .disabled(model.activity == .saving)
                            .help("Forgets the relay and token, and stops sharing every project.")
                    }
                    Button("Apply") { applyRelay(url: relayURL.trimmingCharacters(in: .whitespaces), token: relayToken.isEmpty ? nil : relayToken) }
                        .buttonStyle(.signalCompact)
                        .disabled(!relayDirty || !model.isRunning || model.activity == .saving)
                }
            }
        } header: {
            Text("Relay")
        }
    }

    @ViewBuilder
    private var tunnelStatus: some View {
        if let relay = model.relay {
            switch relay.state {
            case .off:
                StatusLabel(text: "Off", tone: .idle)
            case .idle:
                StatusLabel(text: "Ready · nothing shared", tone: .idle)
            case .connecting:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Connecting…").font(.beaconLabel)
                }
            case .connected:
                let shared = relay.shares.count
                StatusLabel(
                    text: "Connected\(relay.label.map { " as \($0)" } ?? "") · \(shared) shared",
                    tone: .online
                )
            case .failed:
                StatusLabel(text: relay.error ?? "Can't reach the relay", tone: .attention)
                    .help(relay.error ?? "")
            }
        } else {
            StatusLabel(text: "Off", tone: .idle)
        }
    }

    private var relayDirty: Bool {
        relayLoaded && (relayURL.trimmingCharacters(in: .whitespaces) != (model.relay?.url ?? "") || !relayToken.isEmpty)
    }

    private func loadRelay(force: Bool = false) {
        guard !relayLoaded || force else { return }
        relayURL = model.relay?.url ?? ""
        relayLoaded = true
    }

    private func applyRelay(url: String, token: String?) {
        relayError = nil
        Task {
            relayError = await model.setRelay(url: url, token: token)
            if relayError == nil {
                relayToken = ""
                model.pendingInvite = nil
            }
            loadRelay(force: true)
            await model.loadRelayTokens()
        }
    }

    // MARK: - Coding agents

    private var agentsSection: some View {
        Section {
            if model.agents.isEmpty {
                Text("Claude Code and Codex aren't set up for your user yet. Once one is, you can tell it about Beacon here.")
                    .font(.beaconLabel)
                    .foregroundStyle(Color.beaconSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(model.agents, id: \.name) { agent in
                    LabeledContent(agent.name) {
                        if agent.isOutdated {
                            Button("Update instructions") {
                                Task { await model.addAgentInstructions(to: [agent.name], confirmInMenu: false) }
                            }
                            .buttonStyle(.signalCompact)
                            .help("Replaces the instructions an older Beacon added to \(agent.file)")
                        } else if agent.hasInstructions {
                            StatusLabel(text: "Knows about Beacon", tone: .online)
                                .help(agent.file)
                        } else {
                            Button("Add instructions") {
                                Task { await model.addAgentInstructions(to: [agent.name], confirmInMenu: false) }
                            }
                            .buttonStyle(.signalCompact)
                            .help("Adds a section to \(agent.file)")
                        }
                    }
                }
                Text("Adds a short note to each agent's own instructions file, telling it to ask Beacon for a port and give you .\(model.config.primaryTLD) links. The same as `beacon agent-guide --global`.")
                    .font(.beaconLabel)
                    .foregroundStyle(Color.beaconSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Coding agents")
        }
    }

    // MARK: - Service

    private var serviceSection: some View {
        Section {
            LabeledContent("Background service") {
                if model.activity == .restarting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Restarting…").font(.beaconLabel)
                    }
                } else if model.activity == .installing {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(model.serviceOutdated ? "Updating…" : "Installing…").font(.beaconLabel)
                    }
                } else if let status = model.status, model.serviceOutdated {
                    HStack(spacing: 8) {
                        StatusLabel(text: "Outdated · \(status.version)", tone: .attention)
                            .help("The service is \(status.version); this app is \(BeaconPaths.version).")
                        Button("Update…") { explaining = .update }
                            .buttonStyle(.signalCompact)
                    }
                } else if let status = model.status {
                    StatusLabel(text: "Running · version \(status.version)", tone: .online)
                } else {
                    StatusLabel(text: "Not installed", tone: .idle)
                }
            }
            .background { highlight(.service) }
            .id(SettingsHighlight.service)

            LabeledContent("Resolver") {
                if !model.isRunning {
                    StatusLabel(text: "Off", tone: .idle)
                } else if model.resolverActive {
                    StatusLabel(text: "Active for \(model.config.tlds.map { ".\($0)" }.joined(separator: " "))", tone: .online)
                } else {
                    StatusLabel(text: "Missing — restart the service", tone: .attention)
                }
            }

            LabeledContent("HTTPS certificate") {
                if model.activity == .trusting {
                    ProgressView().controlSize(.mini)
                } else if model.caTrusted {
                    StatusLabel(text: "Trusted", tone: .online)
                } else if model.isRunning {
                    Button("Trust…") { explaining = .trust }
                        .buttonStyle(.signalCompact)
                } else {
                    StatusLabel(text: "Not set up", tone: .idle)
                }
            }

            if let outcome, outcome.action == .trust || outcome.action == .update {
                outcomeNote(outcome.result)
            }

            HStack {
                if model.needsSetup {
                    Button("Open setup…") { AppWindows.open(WindowID.setup, with: openWindow) }
                }
                Spacer()
                Button("Restart service") { Task { await model.restartService() } }
                    .disabled(!model.isRunning || model.activity != nil)
                    .help("Restarts Beacon's background service. No password needed.")
            }
        } header: {
            Text("Service")
        }
    }

    // MARK: - Updates

    private var updatesSection: some View {
        Section {
            Toggle("Check for updates automatically", isOn: Binding(
                get: { updater.checksAutomatically },
                set: { updater.checksAutomatically = $0 }
            ))
            .disabled(!updater.isActive)
            HStack {
                Text(updater.isActive ? "Beacon \(BeaconPaths.version)" : "Beacon \(BeaconPaths.version) · updates are off in debug builds")
                    .font(.beaconLabel)
                    .foregroundStyle(Color.beaconSecondaryText)
                Spacer()
                Button("Check for Updates…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        } header: {
            Text("Updates")
        }
    }

    // MARK: - Uninstall

    private var uninstallSection: some View {
        Section {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Uninstall Beacon")
                    Text("Removes the service, resolver, certificate and beacon command.")
                        .font(.beaconLabel)
                        .foregroundStyle(Color.beaconSecondaryText)
                }
                Spacer()
                if model.activity == .uninstalling {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Uninstall…", role: .destructive) { explaining = .uninstall }
                        .buttonStyle(.destructiveCompact)
                        .disabled(!model.isRunning && !model.caTrusted)
                }
            }
            if let outcome, outcome.action == .uninstall {
                outcomeNote(outcome.result)
            }
        }
    }

    @ViewBuilder
    private func outcomeNote(_ result: ActionOutcome) -> some View {
        switch result {
        case .succeeded:
            EmptyView()
        case .cancelled:
            Text("Cancelled — nothing was changed.")
                .font(.beaconLabel)
                .foregroundStyle(Color.beaconSecondaryText)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.beaconLabel)
                .foregroundStyle(.red)
        }
    }

    // MARK: - Pointing at a row

    /// The selection tint behind a row while Settings is pointing at it.
    private func highlight(_ target: SettingsHighlight) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color.beaconSelection)
            .padding(.horizontal, -8)
            .padding(.vertical, -6)
            .opacity(model.settingsHighlight == target ? 1 : 0)
    }

    /// Switches to the row's pane and scrolls to it, then lets the tint fade
    /// once the user has seen it.
    private func reveal(_ target: SettingsHighlight?, with proxy: ScrollViewProxy) {
        guard let target else { return }
        pane = target.pane
        // The window may still be appearing; scroll once it has laid out.
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(target, anchor: .center) }
        }
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard model.settingsHighlight == target else { return }
            withAnimation(.easeOut(duration: 0.8)) { model.settingsHighlight = nil }
        }
    }

    // MARK: -

    private func portField(_ value: Binding<Int>) -> some View {
        TextField("", value: value, format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder)
            .font(.beaconMono)
            .multilineTextAlignment(.center)
            .frame(width: 64)
    }

    private var parsedTLDs: [String] {
        tlds.split(whereSeparator: { $0 == " " || $0 == "," })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased() }
            .filter { !$0.isEmpty }
    }

    private var isDirty: Bool {
        loaded && (parsedTLDs != model.config.tlds
            || rangeStart != model.config.portRangeStart
            || rangeEnd != model.config.portRangeEnd
            || defaultSecure != model.config.defaultSecure)
    }

    private func load(force: Bool = false) {
        guard !loaded || force else { return }
        tlds = model.config.tlds.joined(separator: " ")
        rangeStart = model.config.portRangeStart
        rangeEnd = model.config.portRangeEnd
        defaultSecure = model.config.defaultSecure
        loaded = true
    }

    private func apply() {
        saveError = nil
        let config = BeaconConfig(
            tlds: parsedTLDs.isEmpty ? ["test"] : parsedTLDs,
            portRangeStart: rangeStart,
            portRangeEnd: rangeEnd,
            defaultSecure: defaultSecure
        )
        Task {
            saveError = await model.save(config)
            load(force: true)
        }
    }

    private func run(_ action: PrivilegedAction, purge: Bool) {
        outcome = nil
        Task {
            outcome = (action, await model.perform(action, purge: purge))
            // The macOS prompt took focus; come back to show what happened.
            AppWindows.bringForward(WindowID.settings)
        }
    }
}
