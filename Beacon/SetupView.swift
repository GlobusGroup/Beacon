import SwiftUI

/// First-run setup: the two one-time steps that need the user's permission,
/// in order, each introduced by a `PermissionExplainer` before macOS prompts.
struct SetupView: View {
    @EnvironmentObject private var model: BeaconModel
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var explaining: PrivilegedAction?
    @State private var outcomes: [PrivilegedAction: ActionOutcome] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 32)
                .padding(.top, 36)
                .padding(.bottom, 24)

            VStack(spacing: 0) {
                SetupStepRow(
                    number: 1,
                    title: "Install the background service",
                    detail: "Answers DNS for .test domains and serves your projects on ports 80 and 443.",
                    requirement: "Needs your administrator password",
                    state: serviceState,
                    actionTitle: "Install…"
                ) { explaining = .install }

                Divider().overlay(Color.beaconHairline)

                SetupStepRow(
                    number: 2,
                    title: "Trust Beacon's certificate",
                    detail: "Lets Safari and Chrome open https:// project links without warnings.",
                    requirement: "Confirm with Touch ID or your password",
                    state: certificateState,
                    actionTitle: "Trust…"
                ) { explaining = .trust }
            }
            .beaconCard()
            .padding(.horizontal, 32)

            if !model.needsSetup {
                nextSteps
                    .padding(.horizontal, 32)
                    .padding(.top, 16)
            }

            footer
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
        }
        .frame(width: 560)
        .background(Color.beaconBackground)
        .sheet(item: $explaining) { action in
            PermissionExplainer(action: action) { _ in run(action) }
        }
        .onAppear { AppWindows.becomeRegularApp() }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            BeaconLockup(height: 34)
            VStack(alignment: .leading, spacing: 6) {
                Text(model.needsSetup ? "Set up Beacon" : "Beacon is ready")
                    .font(.beaconTitle)
                    .foregroundStyle(Color.beaconText)
                // The guide's approved product description.
                Text("Beacon gives your local projects .test domains and routes requests to the right local port.")
                    .font(.beaconBody)
                    .foregroundStyle(Color.beaconSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var nextSteps: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ADD YOUR FIRST PROJECT")
                .font(.beaconSectionLabel)
                .foregroundStyle(Color.beaconSecondaryText)
            HStack(spacing: 6) {
                Text("Use Add project in the menu bar, or run")
                    .font(.beaconBody)
                    .foregroundStyle(Color.beaconText)
                Text("beacon register")
                    .font(.beaconMonoLarge)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06)))
                Text("in a project folder.")
                    .font(.beaconBody)
                    .foregroundStyle(Color.beaconText)
            }
        }
    }

    private var footer: some View {
        HStack {
            if model.needsSetup {
                Text("Each step happens once.")
                    .font(.beaconLabel)
                    .foregroundStyle(Color.beaconSecondaryText)
                Spacer()
                Button("Not now") { dismissWindow() }
                    .controlSize(.large)
            } else {
                Spacer()
                Button("Done") { dismissWindow() }
                    .buttonStyle(.signal)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Step state

    private var serviceState: SetupStepRow.State {
        if model.activity == .installing { return .working }
        if model.isRunning { return .done }
        return .ready(note: note(for: .install))
    }

    private var certificateState: SetupStepRow.State {
        if model.activity == .trusting { return .working }
        if model.caTrusted { return .done }
        guard model.isRunning else { return .blocked("Available after step 1") }
        return .ready(note: note(for: .trust))
    }

    private func note(for action: PrivilegedAction) -> SetupStepRow.Note? {
        switch outcomes[action] {
        case .cancelled: return .info("Cancelled — nothing was changed. You can try again.")
        case .failed(let message): return .error(message)
        default: return nil
        }
    }

    private func run(_ action: PrivilegedAction) {
        outcomes[action] = nil
        Task {
            outcomes[action] = await model.perform(action)
            // The macOS prompt took focus; come back to show what happened.
            AppWindows.bringForward(WindowID.setup)
        }
    }
}

struct SetupStepRow: View {
    enum Note: Equatable {
        case info(String)
        case error(String)
    }

    enum State: Equatable {
        case ready(note: Note?)
        case blocked(String)
        case working
        case done
    }

    let number: Int
    let title: String
    let detail: String
    let requirement: String
    let state: State
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            badge
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.beaconBodyEmphasis)
                    .foregroundStyle(Color.beaconText)
                Text(detail)
                    .font(.beaconLabel)
                    .foregroundStyle(Color.beaconSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if state != .done {
                    Label(requirement, systemImage: "key")
                        .font(.beaconCaption)
                        .foregroundStyle(Color.beaconSecondaryText)
                        .padding(.top, 2)
                }

                if case .ready(let note?) = state {
                    noteView(note).padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailing
                .frame(minWidth: 84, alignment: .trailing)
        }
        .padding(16)
    }

    @ViewBuilder
    private var badge: some View {
        ZStack {
            switch state {
            case .done:
                Circle().fill(Color.beaconOnline)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
            case .blocked:
                Circle().strokeBorder(Color.beaconHairline, lineWidth: 1.5)
                Text("\(number)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.beaconSecondaryText)
            default:
                Circle().strokeBorder(Color.beaconText.opacity(0.7), lineWidth: 1.5)
                Text("\(number)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.beaconText)
            }
        }
        .frame(width: 24, height: 24)
    }

    @ViewBuilder
    private var trailing: some View {
        switch state {
        case .ready:
            Button(actionTitle, action: action)
                .buttonStyle(.signal)
        case .blocked(let reason):
            Text(reason)
                .font(.beaconCaption)
                .foregroundStyle(Color.beaconSecondaryText)
                .multilineTextAlignment(.trailing)
        case .working:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for macOS…")
                    .font(.beaconLabel)
                    .foregroundStyle(Color.beaconSecondaryText)
            }
        case .done:
            Text("Done")
                .font(.beaconLabel.weight(.medium))
                .foregroundStyle(Color.beaconOnline)
        }
    }

    @ViewBuilder
    private func noteView(_ note: Note) -> some View {
        switch note {
        case .info(let text):
            Text(text)
                .font(.beaconCaption)
                .foregroundStyle(Color.beaconSecondaryText)
        case .error(let text):
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.beaconCaption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
