import SwiftUI

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

    @State private var explaining: PrivilegedAction?
    @State private var outcome: (action: PrivilegedAction, result: ActionOutcome)?

    var body: some View {
        ScrollViewReader { proxy in
            form
                .onChange(of: model.settingsHighlight, initial: true) { _, target in
                    reveal(target, with: proxy)
                }
        }
    }

    private var form: some View {
        Form {
            routingSection
            sharingSection
            serviceSection
            updatesSection
            uninstallSection
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            load()
            AppWindows.becomeRegularApp()
        }
        .onChange(of: model.config) { _, _ in if !isDirty { load(force: true) } }
        .onChange(of: model.relay?.url) { _, _ in if !relayDirty { loadRelay(force: true) } }
        .sheet(item: $explaining) { action in
            PermissionExplainer(action: action) { purge in run(action, purge: purge) }
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
                    Text("Space-separated TLDs, without the dot. Existing projects keep their ports.")
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
                Text("The background service is older than this app and can't share projects. Update it under Service, below.")
                    .font(.beaconLabel)
                    .foregroundStyle(Color.beaconSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LabeledContent("Relay") {
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
            Text("Sharing")
        }
        .onAppear { loadRelay() }
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
            if relayError == nil { relayToken = "" }
            loadRelay(force: true)
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

    /// Scrolls to the row, then lets the tint fade once the user has seen it.
    private func reveal(_ target: SettingsHighlight?, with proxy: ScrollViewProxy) {
        guard let target else { return }
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
