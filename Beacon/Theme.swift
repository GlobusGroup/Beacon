import AppKit
import SwiftUI

// Beacon's interface tokens, taken from the brand guide (v1.0):
// amber Signal for the main action and selected content only, calm neutral
// surfaces, SF Pro for interface text and SF Mono for hosts, ports and paths.

extension Color {
    // Palette — authoritative values from palette/beacon-colours.json.
    static let beaconSignal = Color(hex: 0xF5B544)
    static let beaconInk = Color(hex: 0x181C20)
    static let beaconCanvas = Color(hex: 0xF5F3EE)
    static let beaconSlate = Color(hex: 0x737C86)
    static let beaconOnline = Color(hex: 0x38A88A)

    // Surfaces. Dark mode leans towards the slate blue of the website's
    // window mockups rather than a neutral grey.
    static let beaconBackground = Color(light: 0xF5F3EE, dark: 0x171E23)
    static let beaconSurface = Color(light: 0xFFFFFF, dark: 0x1F272D)
    static let beaconHairline = Color(light: 0xE4E1DA, dark: 0x2F383F)
    /// The sidebar column in Settings: one step darker than the content.
    static let beaconSidebar = Color(light: 0xEDEAE3, dark: 0x151B20)

    static let beaconText = Color(light: 0x181C20, dark: 0xF5F3EE)
    /// The guide asks for darker text than Slate for small labels on light
    /// surfaces, so light mode uses a deeper grey here.
    static let beaconSecondaryText = Color(light: 0x5B636C, dark: 0x9AA2AB)

    /// Row highlight: Signal at low strength, as in the guide's project table.
    static let beaconSelection = Color(light: 0xFBE7C2, dark: 0x3A3220)
    /// Border of a selected sidebar item: Signal, a little transparent.
    static let beaconSelectionBorder = Color(light: 0xE9B55A, dark: 0x7A5D2C)
    /// Signal as used for icons on light surfaces, where the brand amber is
    /// too pale to read.
    static let beaconSignalIcon = Color(light: 0xC98A1C, dark: 0xF5B544)

    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

extension Font {
    /// 24–28pt semibold page titles.
    static let beaconTitle = Font.system(size: 24, weight: .semibold)
    static let beaconHeading = Font.system(size: 15, weight: .semibold)
    /// 13–15pt body.
    static let beaconBody = Font.system(size: 13)
    static let beaconBodyEmphasis = Font.system(size: 13, weight: .medium)
    /// 11–12pt supporting labels.
    static let beaconLabel = Font.system(size: 12)
    static let beaconCaption = Font.system(size: 11)
    static let beaconSectionLabel = Font.system(size: 11, weight: .semibold)

    /// SF Mono, for anything a developer might type or paste.
    static let beaconMono = Font.system(size: 12, design: .monospaced)
    static let beaconMonoLarge = Font.system(size: 13, design: .monospaced)
}

// MARK: - Buttons

/// The one amber button on a screen. Ink text on Signal, as the guide asks —
/// white text on amber fails contrast.
struct SignalButtonStyle: ButtonStyle {
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .semibold))
            .foregroundStyle(Color.beaconInk)
            .padding(.horizontal, compact ? 10 : 14)
            .frame(height: compact ? 24 : 28)
            .background(
                RoundedRectangle(cornerRadius: compact ? 6 : 7, style: .continuous)
                    .fill(LinearGradient.beaconSignal)
                    .brightness(configuration.isPressed ? -0.08 : 0)
            )
            .overlay(
                RoundedRectangle(cornerRadius: compact ? 6 : 7, style: .continuous)
                    .strokeBorder(Color(hex: 0xFFCF79), lineWidth: 0.5)
            )
            .shadow(color: Color.beaconSignal.opacity(isEnabled ? 0.18 : 0), radius: 6, y: 1)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

extension LinearGradient {
    /// The amber buttons on the website: lighter at the top left.
    static let beaconSignal = LinearGradient(
        colors: [Color(hex: 0xFFD47E), Color(hex: 0xF5B544), Color(hex: 0xEEA72E)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
}

/// Removal actions. Same shape as `SignalButtonStyle` so the two sit level,
/// and drawn by hand so it stays red in a window that isn't key — native
/// prominent buttons fade to grey there.
struct DestructiveButtonStyle: ButtonStyle {
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 10 : 14)
            .frame(height: compact ? 24 : 28)
            .background(
                RoundedRectangle(cornerRadius: compact ? 6 : 7, style: .continuous)
                    .fill(Color(nsColor: .systemRed))
                    .brightness(configuration.isPressed ? -0.08 : 0)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == DestructiveButtonStyle {
    static var destructive: DestructiveButtonStyle { DestructiveButtonStyle() }
    static var destructiveCompact: DestructiveButtonStyle { DestructiveButtonStyle(compact: true) }
}

/// Text-only footer actions: quiet until hovered.
struct QuietButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.beaconLabel)
            .foregroundStyle(isHovering ? Color.beaconText : Color.beaconSecondaryText)
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.1 : isHovering ? 0.06 : 0))
            )
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
    }
}

extension ButtonStyle where Self == SignalButtonStyle {
    static var signal: SignalButtonStyle { SignalButtonStyle() }
    static var signalCompact: SignalButtonStyle { SignalButtonStyle(compact: true) }
}

extension ButtonStyle where Self == QuietButtonStyle {
    static var quiet: QuietButtonStyle { QuietButtonStyle() }
}

// MARK: - Status

/// A status is always a colour *and* a word — never colour alone.
struct StatusLabel: View {
    enum Tone { case online, idle, attention }

    let text: String
    let tone: Tone

    var body: some View {
        HStack(spacing: 6) {
            indicator
            Text(text)
                .font(.beaconLabel)
                .foregroundStyle(tone == .idle ? Color.beaconSecondaryText : Color.beaconText)
        }
    }

    @ViewBuilder
    private var indicator: some View {
        switch tone {
        case .online:
            Circle().fill(Color.beaconOnline).frame(width: 7, height: 7)
        case .idle:
            Circle().strokeBorder(Color.beaconSlate, lineWidth: 1.5).frame(width: 7, height: 7)
        case .attention:
            Circle().fill(Color.beaconSignal).frame(width: 7, height: 7)
        }
    }
}

/// The same status as a small pill, for project rows: tinted capsule,
/// coloured dot, word. Still never colour alone.
struct StatusBadge: View {
    let text: String
    let tone: StatusLabel.Tone

    var body: some View {
        HStack(spacing: 5) {
            switch tone {
            case .online: Circle().fill(Color.beaconOnline).frame(width: 6, height: 6)
            case .idle: Circle().strokeBorder(Color.beaconSlate, lineWidth: 1.2).frame(width: 6, height: 6)
            case .attention: Circle().fill(Color.beaconSignal).frame(width: 6, height: 6)
            }
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(foreground)
        }
        .padding(.horizontal, 8)
        // One width for every state, so a list of badges lines up.
        .frame(width: 78, height: 20, alignment: .leading)
        .background(Capsule().fill(tint.opacity(0.16)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.22), lineWidth: 0.5))
        .fixedSize()
    }

    private var tint: Color {
        switch tone {
        case .online: .beaconOnline
        case .idle: .beaconSlate
        case .attention: .beaconSignal
        }
    }

    private var foreground: Color {
        switch tone {
        case .online: Color(light: 0x1F6E58, dark: 0xD1F6E4)
        case .idle: .beaconSecondaryText
        case .attention: Color(light: 0x8A5A0B, dark: 0xFFE2A8)
        }
    }
}

// MARK: - Sidebar

/// One entry in a sidebar: amber icon, amber hairline and a warm tint when
/// selected, as in the website's window mockup.
struct SidebarItem: View {
    let title: String
    let symbol: String
    let selected: Bool
    var attention = false
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 18)
                .foregroundStyle(selected ? Color.beaconSignalIcon : Color.beaconSecondaryText)
            Text(title)
                .font(.system(size: 13, weight: selected ? .medium : .regular))
                .foregroundStyle(Color.beaconText)
            Spacer()
            if attention {
                Circle().fill(Color.beaconSignal).frame(width: 7, height: 7)
                    .accessibilityLabel("Needs attention")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected
                      ? AnyShapeStyle(LinearGradient(
                          colors: [Color.beaconSelection, Color.beaconSelection.opacity(0.45)],
                          startPoint: .leading, endPoint: .trailing))
                      : AnyShapeStyle(Color.primary.opacity(isHovering ? 0.05 : 0)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? Color.beaconSelectionBorder : .clear, lineWidth: 0.75)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Brand artwork

struct BeaconSymbol: View {
    var size: CGFloat

    var body: some View {
        Image("BeaconSymbol")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityLabel("Beacon")
    }
}

/// The lowercase wordmark. The guide keeps it on light surfaces, so in dark
/// mode this falls back to the symbol alone.
struct BeaconLockup: View {
    @Environment(\.colorScheme) private var colorScheme
    var height: CGFloat

    var body: some View {
        if colorScheme == .dark {
            BeaconSymbol(size: height * 1.15)
        } else {
            Image("BeaconWordmark")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(height: height)
                .accessibilityLabel("Beacon")
        }
    }
}

// MARK: - Surfaces

extension View {
    /// A raised card on the canvas: white in light mode, one step up from Ink in dark.
    func beaconCard(radius: CGFloat = 10) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Color.beaconSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.beaconHairline, lineWidth: 1)
        )
    }
}
