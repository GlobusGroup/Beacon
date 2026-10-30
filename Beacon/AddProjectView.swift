import SwiftUI

/// Its own window rather than a sheet on the menu bar popover: the folder
/// picker takes focus, and a popover closes — taking its sheet with it — the
/// moment it loses focus.
struct AddProjectView: View {
    @EnvironmentObject private var model: BeaconModel
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var name = ""
    @State private var domain = ""
    @State private var path = ""
    @State private var secure = true
    @State private var isWorking = false
    @State private var error: String?
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
        .onAppear { secure = model.config.defaultSecure }
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

            Text("The port comes from \(String(model.config.portRangeStart))–\(String(model.config.portRangeEnd)) and stays with this project.")
                .font(.beaconLabel)
                .foregroundStyle(Color.beaconSecondaryText)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.beaconLabel)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
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
                .disabled(Site.slug(name).isEmpty || isWorking)
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
        Task {
            let result = await model.register(
                name: name,
                domain: domain.isEmpty ? nil : domain,
                path: path.isEmpty ? nil : path,
                secure: secure
            )
            isWorking = false
            switch result {
            case .success(let site): added = site
            case .failure(let failure): error = failure.message
            }
        }
    }

    private func reset() {
        name = ""
        domain = ""
        path = ""
        error = nil
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
