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

/// One project. Click to open it; the context menu has the rest.
struct ProjectRow: View {
    @EnvironmentObject private var model: BeaconModel
    @State private var isHovering = false
    @State private var confirmingRemoval = false
    let site: Site

    var body: some View {
        HStack(spacing: 12) {
            Text(site.domain)
                .font(.beaconBodyEmphasis)
                .foregroundStyle(Color.beaconText)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(verbatim: "localhost:\(site.port)")
                .font(.beaconMono)
                .foregroundStyle(Color.beaconSecondaryText)

            StatusLabel(
                text: model.isUp(site) ? "Online" : "Offline",
                tone: model.isUp(site) ? .online : .idle
            )
            .frame(width: 64, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isHovering ? Color.beaconSelection : .clear)
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { model.open(site) }
        .help(model.isUp(site)
              ? "Open \(site.url)"
              : "Nothing is listening on port \(site.port). Start the project's dev server on that port.")
        .contextMenu {
            Button("Open in browser") { model.open(site) }
            Button("Copy URL") { model.copy(site.url) }
            Button("Copy port") { model.copy(String(site.port)) }
            if site.path != nil {
                Button("Show in Finder") { model.revealInFinder(site) }
            }
            Divider()
            Button("Remove project…", role: .destructive) { confirmingRemoval = true }
        }
        .confirmationDialog(
            "Remove \(site.domain)?",
            isPresented: $confirmingRemoval
        ) {
            Button("Remove project", role: .destructive) {
                Task { await model.remove(site) }
            }
        } message: {
            Text("Beacon stops routing \(site.domain) and releases port \(String(site.port)), which may be given to another project.")
        }
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
