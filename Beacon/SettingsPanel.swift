import SwiftUI

struct SettingsPanel: View {
    @EnvironmentObject private var model: BeaconModel
    @Environment(\.openWindow) private var openWindow

    @State private var tlds = ""
    @State private var rangeStart = 3100
    @State private var rangeEnd = 3999
    @State private var defaultSecure = true
    @State private var loaded = false
    @State private var saveError: String?

    @State private var explaining: PrivilegedAction?
    @State private var outcome: (action: PrivilegedAction, result: ActionOutcome)?

    var body: some View {
        Form {
            routingSection
            serviceSection
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

    // MARK: - Service

    private var serviceSection: some View {
        Section {
            LabeledContent("Background service") {
                if model.activity == .restarting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Restarting…").font(.beaconLabel)
                    }
                } else if let status = model.status {
                    StatusLabel(text: "Running · version \(status.version)", tone: .online)
                } else {
                    StatusLabel(text: "Not installed", tone: .idle)
                }
            }

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

            if let outcome, outcome.action == .trust {
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
