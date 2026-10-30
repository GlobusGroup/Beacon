import SwiftUI

/// Shown before every macOS permission prompt, so a system dialog never
/// appears out of nowhere. It says what is about to change, describes the
/// dialog that comes next, and only then hands over to macOS.
struct PermissionExplainer: View {
    let action: PrivilegedAction
    /// Called with whether the user also asked to forget their projects
    /// (uninstall only).
    let onContinue: (_ purge: Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var purge = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: content.symbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color.beaconText)
                    .frame(width: 44, height: 44)
                    .beaconCard()

                VStack(alignment: .leading, spacing: 4) {
                    Text(content.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.beaconText)
                    Text(content.lead)
                        .font(.beaconBody)
                        .foregroundStyle(Color.beaconSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(content.listHeading.uppercased())
                    .font(.beaconSectionLabel)
                    .foregroundStyle(Color.beaconSecondaryText)
                ForEach(content.changes, id: \.text) { change in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: change.symbol)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.beaconSlate)
                            .frame(width: 16)
                        // Markdown, so `commands` and `paths` set in SF Mono.
                        Text(LocalizedStringKey(change.text))
                            .font(.beaconBody)
                            .foregroundStyle(Color.beaconText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if action == .uninstall {
                Toggle("Also forget registered projects and their ports", isOn: $purge)
                    .font(.beaconBody)
                    .toggleStyle(.checkbox)
            }

            nextStep

            Text(content.footnote)
                .font(.beaconCaption)
                .foregroundStyle(Color.beaconSecondaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
                confirmButton
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(Color.beaconBackground)
    }

    /// A sketch of the system dialog that follows, so it's recognisable when it appears.
    private var nextStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("WHAT HAPPENS NEXT")
                .font(.beaconSectionLabel)
                .foregroundStyle(Color.beaconSecondaryText)

            HStack(alignment: .top, spacing: 12) {
                Image(systemName: content.promptSymbol)
                    .font(.system(size: 18))
                    .foregroundStyle(Color.beaconSlate)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 4) {
                    Text(content.promptTitle)
                        .font(.beaconBodyEmphasis)
                        .foregroundStyle(Color.beaconText)
                    Text(content.promptDetail)
                        .font(.beaconLabel)
                        .foregroundStyle(Color.beaconSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .beaconCard()
        }
    }

    @ViewBuilder
    private var confirmButton: some View {
        if action == .uninstall {
            Button("Uninstall", role: .destructive) { confirm() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.destructive)
        } else {
            Button("Continue") { confirm() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.signal)
        }
    }

    private func confirm() {
        dismiss()
        onContinue(purge)
    }

    // MARK: - Copy

    private struct Change {
        let symbol: String
        let text: String
    }

    private struct Content {
        let symbol: String
        let title: String
        let lead: String
        let listHeading: String
        let changes: [Change]
        let promptSymbol: String
        let promptTitle: String
        let promptDetail: String
        let footnote: String
    }

    private var content: Content {
        switch action {
        case .install:
            return Content(
                symbol: "lock.shield",
                title: "macOS will ask for your password",
                lead: "Installing Beacon's background service needs administrator access. You'll only be asked once.",
                listHeading: "What gets installed",
                changes: [
                    Change(symbol: "network", text: "A DNS resolver for `.test`, so every project domain points at this Mac"),
                    Change(symbol: "arrow.left.arrow.right", text: "A proxy on ports 80 and 443 that sends each domain to its project's port"),
                    Change(symbol: "terminal", text: "The `beacon` command, in `/usr/local/bin`"),
                ],
                promptSymbol: "person.badge.key",
                promptTitle: "“Allow administrator access for Beacon?”",
                // The verification note is macOS's wording for apps that
                // aren't notarised. Revisit this line once builds are.
                promptDetail: "Enter your Mac login password and click Allow Access. macOS also says it couldn't verify Beacon — it says that about any app that hasn't been notarised by Apple.",
                footnote: "Adding projects, changing settings and restarting the service never ask for a password."
            )

        case .trust:
            return Content(
                symbol: "checkmark.shield",
                title: "macOS will ask you to approve a certificate",
                lead: "Beacon issues its own certificates so https:// links to your projects work without browser warnings.",
                listHeading: "What changes",
                changes: [
                    Change(symbol: "lock", text: "Beacon's certificate authority is added to your login keychain"),
                    Change(symbol: "person", text: "Only your user account trusts it, and only for certificates Beacon issues"),
                    Change(symbol: "safari", text: "Safari and Chrome accept `https://myproject.test`"),
                ],
                promptSymbol: "touchid",
                promptTitle: "“You are making changes to your Certificate Trust Settings.”",
                promptDetail: "Confirm with Touch ID, or enter your password.",
                footnote: "Uninstalling Beacon removes the certificate again."
            )

        case .uninstall:
            return Content(
                symbol: "trash",
                title: "Uninstall Beacon",
                lead: "Removes the background service and everything Beacon added to this Mac. Your projects' own files aren't touched.",
                listHeading: "What gets removed",
                changes: [
                    Change(symbol: "network", text: "The `.test` resolver and the proxy on ports 80 and 443"),
                    Change(symbol: "lock", text: "Beacon's certificate, from your login keychain"),
                    Change(symbol: "terminal", text: "The `beacon` command, from `/usr/local/bin`"),
                ],
                promptSymbol: "person.badge.key",
                promptTitle: "Up to two macOS prompts",
                promptDetail: "macOS may first ask you to confirm removing the certificate, then shows “Allow administrator access for Beacon?” to remove the service.",
                footnote: "You can install Beacon again from its setup window at any time."
            )
        }
    }
}
