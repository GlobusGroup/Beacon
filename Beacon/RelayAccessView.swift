import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A `.beacon` relay invite, declared in Beacon-Info.plist.
    static let beaconInvite = UTType(exportedAs: RelayInvite.typeIdentifier, conformingTo: .json)
}

/// A new token as a file, for the save panel.
struct InviteDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.beaconInvite]

    var invite: RelayInvite

    init(invite: RelayInvite) { self.invite = invite }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        invite = try BeaconJSON.decoder.decode(RelayInvite.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let wrapper = FileWrapper(regularFileWithContents: try invite.encoded())
        // It holds a working token.
        wrapper.fileAttributes[FileAttributeKey.posixPermissions.rawValue] = 0o600
        return wrapper
    }
}

/// Everyone who can use the relay, for an admin: make tokens, hand them out
/// as `.beacon` files, revoke them.
struct RelayAccessView: View {
    @EnvironmentObject private var model: BeaconModel
    @Environment(\.dismiss) private var dismiss

    private enum Mode {
        case list
        case creating
        /// The token exists now, and this is the only time it's available.
        case created(RelayInvite)
    }

    @State private var mode = Mode.list
    @State private var label = ""
    @State private var note = ""
    @State private var admin = false
    @State private var working = false
    @State private var error: String?
    @State private var revoking: RelayToken?
    @State private var saving = false
    @State private var savedTo: URL?

    init() {}

    #if DEBUG
    /// Opens on the screen shown just after making a token, for snapshots.
    init(justCreated invite: RelayInvite) {
        _mode = State(initialValue: .created(invite))
    }
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Relay access").font(.beaconHeading)
                Text(model.relay?.url ?? "")
                    .font(.beaconMono)
                    .foregroundStyle(Color.beaconSecondaryText)
            }

            switch mode {
            case .list: tokenList
            case .creating: createForm
            case .created(let invite): createdView(invite)
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.beaconLabel)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task { error = await model.loadRelayTokens() }
    }

    // MARK: - List

    private var tokenList: some View {
        VStack(alignment: .leading, spacing: 12) {
            List(model.relayTokens ?? []) { token in
                row(token)
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(height: 280)

            HStack {
                Button {
                    Task {
                        working = true
                        error = await model.loadRelayTokens()
                        working = false
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
                .disabled(working)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("New token…") {
                    label = ""
                    note = ""
                    admin = false
                    error = nil
                    mode = .creating
                }
                .buttonStyle(.signalCompact)
            }
        }
        .confirmationDialog(
            "Revoke \(revoking?.label ?? "")'s token?",
            isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
            presenting: revoking
        ) { token in
            Button("Revoke", role: .destructive) { revoke(token) }
        } message: { token in
            Text(token.connected
                 ? "Their Mac is connected now. Its tunnel closes and everything it shares goes offline."
                 : "Their Mac won't be able to connect to the relay again.")
        }
    }

    private func row(_ token: RelayToken) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(token.connected ? Color.beaconOnline : Color.beaconHairline)
                .frame(width: 8, height: 8)
                .help(token.connected ? "Connected now" : "Not connected")
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(token.label).font(.beaconBodyEmphasis)
                    if token.admin { tag("Admin") }
                    if token.label == model.relay?.label { tag("You") }
                }
                Text(detail(token))
                    .font(.beaconCaption)
                    .foregroundStyle(Color.beaconSecondaryText)
                    .lineLimit(2)
            }
            Spacer()
            if token.source == .environment {
                Text("Set on server")
                    .font(.beaconCaption)
                    .foregroundStyle(Color.beaconSecondaryText)
                    .help("This token is in the relay's BEACON_TOKENS. Remove it there and redeploy to revoke it.")
            } else if token.label != model.relay?.label {
                Button("Revoke", role: .destructive) { revoking = token }
                    .buttonStyle(.destructiveCompact)
                    .disabled(working)
            }
        }
        .padding(.vertical, 4)
    }

    private func detail(_ token: RelayToken) -> String {
        var parts: [String] = []
        if let note = token.note { parts.append(note) }
        if let created = token.createdAt {
            let date = created.formatted(date: .abbreviated, time: .omitted)
            parts.append(token.createdBy.map { "added by \($0), \(date)" } ?? "added \(date)")
        }
        if !token.shares.isEmpty {
            parts.append("sharing \(token.shares.count) project\(token.shares.count == 1 ? "" : "s")")
        }
        return parts.isEmpty ? "No note" : parts.joined(separator: " · ")
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.beaconCaption)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.beaconSelection, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    // MARK: - New token

    private var createForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Form {
                TextField("Label", text: $label, prompt: Text("sam"))
                    .font(.beaconMono)
                TextField("Who it's for", text: $note, prompt: Text("Sam's MacBook"))
                Toggle("Can manage tokens too", isOn: $admin)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 170)

            Text("The label ends every URL they share: a project called shop becomes shop-\(normalisedLabel.isEmpty ? "label" : normalisedLabel).<relay domain>. Lowercase letters, digits and hyphens.")
                .font(.beaconLabel)
                .foregroundStyle(Color.beaconSecondaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Back") {
                    error = nil
                    mode = .list
                }
                .keyboardShortcut(.cancelAction)
                Button("Create token") { create() }
                    .buttonStyle(.signalCompact)
                    .keyboardShortcut(.defaultAction)
                    .disabled(normalisedLabel.isEmpty || working)
            }
        }
    }

    private var normalisedLabel: String {
        label.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private func create() {
        error = nil
        working = true
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let spec = RelayTokenSpec(label: normalisedLabel, note: trimmedNote.isEmpty ? nil : trimmedNote, admin: admin)
        Task {
            switch await model.createRelayToken(spec) {
            case .success(let invite):
                savedTo = nil
                mode = .created(invite)
                saving = true
            case .failure(let failure):
                error = failure.message
            }
            working = false
        }
    }

    // MARK: - Created

    private func createdView(_ invite: RelayInvite) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color.beaconOnline)
                    .font(.system(size: 18))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Made a token for \(invite.label)").font(.beaconBodyEmphasis)
                    Text("Send them the .beacon file. Opening it in Beacon fills in their relay settings. The token is only in that file and can't be shown again, so save it before you close this.")
                        .font(.beaconLabel)
                        .foregroundStyle(Color.beaconSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let savedTo {
                HStack {
                    Label(savedTo.path(percentEncoded: false), systemImage: "doc")
                        .font(.beaconMono)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([savedTo]) }
                        .controlSize(.small)
                }
            }

            HStack {
                Spacer()
                Button(savedTo == nil ? "Save .beacon file…" : "Save another copy…") { saving = true }
                Button("Done") {
                    error = nil
                    mode = .list
                }
                .buttonStyle(.signalCompact)
                .keyboardShortcut(.defaultAction)
            }
        }
        .fileExporter(
            isPresented: $saving,
            document: InviteDocument(invite: invite),
            contentType: .beaconInvite,
            defaultFilename: "\(invite.label).\(RelayInvite.fileExtension)"
        ) { result in
            switch result {
            case .success(let url): savedTo = url
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }

    // MARK: -

    private func revoke(_ token: RelayToken) {
        error = nil
        working = true
        Task {
            error = await model.revokeRelayToken(token.label)
            working = false
        }
    }
}
