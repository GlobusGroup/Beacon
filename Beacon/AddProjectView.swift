import SwiftUI

/// Its own window rather than a sheet on the menu bar popover: the folder
/// picker takes focus, and a popover closes — taking its sheet with it — the
/// moment it loses focus.
struct AddProjectView: View {
    @EnvironmentObject private var model: BeaconModel
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var name = ""
    @State private var domain = ""
    @State private var port = ""
    @State private var path = ""
    @State private var secure = true
    @State private var isWorking = false
    @State private var error: String?
    /// A free port the daemon offered when it refused the one asked for.
    @State private var errorSuggestion: Int?
    @State private var added: Site?

    var body: some View {
        Group {
            if let added {
                AddedProjectView(site: added) {
                    reset()
                } onDone: {
                    dismissWindow()
                    reset()
                }
            } else {
                form
            }
        }
        .frame(width: 460)
        .background(Color.beaconBackground)
        .onAppear {
            secure = model.config.defaultSecure
            AppWindows.becomeRegularApp()
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add project")
                    .font(.beaconTitle)
                    .foregroundStyle(Color.beaconText)
                Text("Beacon reserves a port for the project and routes its domain to it.")
                    .font(.beaconBody)
                    .foregroundStyle(Color.beaconSecondaryText)
            }

            VStack(spacing: 0) {
                field("Name") {
                    TextField("", text: $name, prompt: placeholder("myproject"))
                        .textFieldStyle(.plain)
                        .font(.beaconBody)
                }
                Divider().overlay(Color.beaconHairline)
                field("Domain") {
                    TextField("", text: $domain, prompt: placeholder(suggestedDomain))
                        .textFieldStyle(.plain)
                        .font(.beaconMonoLarge)
                }
                Divider().overlay(Color.beaconHairline)
                field("Port") {
                    TextField("", text: $port, prompt: placeholder("Automatic"))
                        .textFieldStyle(.plain)
                        .font(.beaconMonoLarge)
                        .onChange(of: port) { _, _ in
                            error = nil
                            errorSuggestion = nil
                        }
                }
                Divider().overlay(Color.beaconHairline)
                field("Folder") {
                    HStack(spacing: 8) {
                        Text(path.isEmpty ? "Optional" : abbreviated(path))
                            .font(path.isEmpty ? .beaconBody : .beaconMono)
                            .foregroundStyle(path.isEmpty ? Color.beaconSecondaryText.opacity(0.7) : Color.beaconText)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Choose…", action: chooseFolder)
                            .controlSize(.small)
                    }
                }
                Divider().overlay(Color.beaconHairline)
                field("Links") {
                    Picker("", selection: $secure) {
                        Text("https://").tag(true)
                        Text("http://").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .beaconCard()

            portNote

            if let error {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.beaconLabel)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    if let errorSuggestion {
                        Spacer(minLength: 0)
                        useButton(errorSuggestion)
                    }
                }
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") {
                    dismissWindow()
                    reset()
                }
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)

                Button {
                    submit()
                } label: {
                    if isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Add project")
                    }
                }
                .buttonStyle(.signal)
                .keyboardShortcut(.defaultAction)
                .disabled(Site.slug(name).isEmpty || isWorking || portCheck.blocksSubmit)
            }
        }
        .padding(24)
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.beaconLabel)
                .foregroundStyle(Color.beaconSecondaryText)
                .frame(width: 56, alignment: .leading)
            content()
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 40)
    }

    // MARK: - Port

    private enum PortCheck {
        case automatic
        case invalid
        case beacon(suggestion: Int?)
        case taken(by: Site, suggestion: Int?)
        case busy(Int)
        case free(Int)

        var blocksSubmit: Bool {
            switch self {
            case .invalid, .beacon, .taken: return true
            case .automatic, .busy, .free: return false
            }
        }
    }

    /// Checked as the user types, against the same rules the daemon applies,
    /// so a clash shows before they press Add rather than after.
    private var portCheck: PortCheck {
        let trimmed = port.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .automatic }
        guard let value = Int(trimmed), (1...65535).contains(value) else { return .invalid }

        let slug = Site.slug(name)
        let others = model.sites.filter { $0.name != slug }
        if daemonPorts.contains(value) {
            return .beacon(suggestion: suggestPort(near: value, avoiding: others))
        }
        if let owner = others.first(where: { $0.port == value }) {
            return .taken(by: owner, suggestion: suggestPort(near: value, avoiding: others))
        }
        // This project's own server already up on its own port isn't a clash.
        let ownPort = model.sites.first { $0.name == slug }?.port
        if ownPort != value, PortProbe.isListening(value) { return .busy(value) }
        return .free(value)
    }

    private var daemonPorts: Set<Int> {
        guard let status = model.status else { return [] }
        return [status.httpPort, status.httpsPort, status.dnsPort]
    }

    private func suggestPort(near port: Int, avoiding others: [Site]) -> Int? {
        let taken = Set(others.map(\.port)).union(daemonPorts)
        let start = max(port, 1024)
        return (start...min(65535, start + 1000)).first {
            !taken.contains($0) && !PortProbe.isListening($0)
        }
    }

    @ViewBuilder
    private var portNote: some View {
        switch portCheck {
        case .automatic:
            note("Beacon picks a free port from \(String(model.config.portRangeStart))–\(String(model.config.portRangeEnd)) and keeps it for this project.")
        case .invalid:
            note("A port is a number from 1 to 65535.", color: .red, icon: "exclamationmark.triangle.fill")
        case .beacon(let suggestion):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                note("Beacon itself listens on port \(port.trimmingCharacters(in: .whitespaces)).",
                     color: .red, icon: "exclamationmark.triangle.fill")
                if let suggestion { Spacer(minLength: 0); useButton(suggestion) }
            }
        case .taken(let owner, let suggestion):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                note("Port \(String(owner.port)) is reserved for \(owner.name) (\(owner.domain)).",
                     color: .red, icon: "exclamationmark.triangle.fill")
                if let suggestion { Spacer(minLength: 0); useButton(suggestion) }
            }
        case .busy(let value):
            note("Something is already listening on \(String(value)). Beacon will reserve it, but make sure it's this project's server.",
                 color: .orange, icon: "exclamationmark.circle.fill")
        case .free(let value):
            note("Port \(String(value)) is free and will stay with this project.")
        }
    }

    private func note(_ text: String, color: Color = .beaconSecondaryText, icon: String? = nil) -> some View {
        Group {
            if let icon {
                Label(text, systemImage: icon)
            } else {
                Text(text)
            }
        }
        .font(.beaconLabel)
        .foregroundStyle(color)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func useButton(_ suggestion: Int) -> some View {
        Button("Use \(String(suggestion))") { port = String(suggestion) }
            .controlSize(.small)
    }

    // MARK: -

    /// Explicitly faint: an unstyled prompt in a plain field can read as a
    /// value that's already been filled in.
    private func placeholder(_ text: String) -> Text {
        Text(text).foregroundStyle(Color.beaconSecondaryText.opacity(0.55))
    }

    private var suggestedDomain: String {
        let slug = Site.slug(name)
        return "\(slug.isEmpty ? "myproject" : slug).\(model.config.primaryTLD)"
    }

    private func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        path = url.path
        // A folder picked before a name is almost always the project itself.
        if name.isEmpty { name = url.lastPathComponent }
    }

    private func submit() {
        isWorking = true
        error = nil
        errorSuggestion = nil
        Task {
            let result = await model.register(
                name: name,
                domain: domain.isEmpty ? nil : domain,
                port: Int(port.trimmingCharacters(in: .whitespaces)),
                path: path.isEmpty ? nil : path,
                secure: secure
            )
            isWorking = false
            switch result {
            case .success(let site): added = site
            case .failure(let failure):
                error = failure.message
                errorSuggestion = failure.details?["suggestedPort"].flatMap(Int.init)
            }
        }
    }

    private func reset() {
        name = ""
        domain = ""
        port = ""
        path = ""
        error = nil
        errorSuggestion = nil
        added = nil
        secure = model.config.defaultSecure
    }
}

/// What Beacon just reserved, with the two values the user needs next.
private struct AddedProjectView: View {
    @EnvironmentObject private var model: BeaconModel
    let site: Site
    let onAddAnother: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.beaconOnline)
                Text("\(site.domain) is ready")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.beaconText)
            }

            VStack(spacing: 0) {
                valueRow(label: "URL", value: site.url)
                Divider().overlay(Color.beaconHairline)
                valueRow(label: "Port", value: String(site.port))
            }
            .beaconCard()

            Text("Start the project's dev server on port \(String(site.port)), then open \(site.url).")
                .font(.beaconLabel)
                .foregroundStyle(Color.beaconSecondaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Add another", action: onAddAnother)
                    .controlSize(.large)
                Spacer()
                Button("Open in browser") { model.open(site) }
                    .controlSize(.large)
                Button("Done", action: onDone)
                    .buttonStyle(.signal)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
    }

    private func valueRow(label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.beaconLabel)
                .foregroundStyle(Color.beaconSecondaryText)
                .frame(width: 56, alignment: .leading)
            Text(value)
                .font(.beaconMonoLarge)
                .foregroundStyle(Color.beaconText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Copy") { model.copy(value) }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 40)
    }
}
