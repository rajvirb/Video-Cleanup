import AppKit
import CoreText
import SwiftUI

/// Sift's look, after the Digital Pockets website: warm off-white (or near-black violet)
/// backgrounds, white cards with hairline borders, one violet accent used sparingly, and
/// Bricolage Grotesque for headings. Every colour follows the Mac's light or dark appearance.
enum Theme {
    // MARK: colours (light, dark)

    static let bg = adaptive(0xFAF8F4, 0x0B0A10)
    static let bg2 = adaptive(0xF3F0EA, 0x100E17)
    static let surface = adaptive(0xFFFFFF, 0x15131D)
    static let surface2 = adaptive(0xFFFFFF, 0x1C1927)
    static let surface3 = adaptive(0xEFEBF6, 0x252135)
    static let ink = adaptive(0x15121D, 0xF4F2FA)
    static let ink2 = adaptive(0x484356, 0xBDB7CC)
    static let muted = adaptive(0x686376, 0x8F8A9F)
    static let border = adaptive(0x15121D, 0xFFFFFF, lightAlpha: 0.10, darkAlpha: 0.08)
    static let borderStrong = adaptive(0x15121D, 0xFFFFFF, lightAlpha: 0.18, darkAlpha: 0.15)
    static let accent = adaptive(0x6B38F0, 0x7F52FF)
    static let accentHover = adaptive(0x5727CF, 0x9B78FF)
    static let accentText = adaptive(0x5727CF, 0xB9A0FF)
    static let accentSoft = adaptive(0x6B38F0, 0x7F52FF, lightAlpha: 0.10, darkAlpha: 0.14)
    static let success = adaptive(0x17784B, 0x4AD295)
    static let successSoft = adaptive(0x17784B, 0x4AD295, lightAlpha: 0.10, darkAlpha: 0.12)
    static let danger = adaptive(0xB4382F, 0xFF7A70)
    static let dangerSoft = adaptive(0xB4382F, 0xFF7A70, lightAlpha: 0.10, darkAlpha: 0.14)
    static let warning = adaptive(0x8A5A00, 0xF2C46D)
    static let warningSoft = adaptive(0xB7791F, 0xF2C46D, lightAlpha: 0.12, darkAlpha: 0.14)

    // MARK: shapes

    static let radiusSmall: CGFloat = 6
    static let radius: CGFloat = 10
    static let radiusLarge: CGFloat = 16

    // MARK: type

    /// The display face, for headings. (Body text uses the Mac's own font, which is close
    /// to the website's.)
    static func display(_ size: CGFloat, bold: Bool = true) -> Font {
        .custom(bold ? "BricolageGrotesque-48ptBold" : "BricolageGrotesque-24ptSemiBold", size: size)
    }

    /// Makes the bundled fonts available to the app.
    static func registerFonts() {
        for url in Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [] {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    private static func adaptive(_ light: UInt32, _ dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? rgb(dark, darkAlpha) : rgb(light, lightAlpha)
        })
    }

    private static func rgb(_ hex: UInt32, _ alpha: CGFloat) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

// MARK: - pieces used across the screens

/// A white (or deep violet) card with a hairline border.
struct Card: ViewModifier {
    var padding: CGFloat = 18
    var radius: CGFloat = Theme.radiusLarge

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: radius).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Theme.border))
            .shadow(color: .black.opacity(0.04), radius: 10, y: 4)
    }
}

extension View {
    func card(padding: CGFloat = 18, radius: CGFloat = Theme.radiusLarge) -> some View {
        modifier(Card(padding: padding, radius: radius))
    }
}

/// The small uppercase label with a violet square, as above the website's headings.
struct Eyebrow: View {
    let text: String

    var body: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 2).fill(Theme.accent).frame(width: 8, height: 8)
            Text(text.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(Theme.accentText)
        }
    }
}

/// The main button: violet, with a soft glow.
struct PrimaryButtonStyle: ButtonStyle {
    var color: Color = Theme.accent
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 16).padding(.vertical, 8)
            .foregroundStyle(.white)
            .background(RoundedRectangle(cornerRadius: Theme.radius)
                .fill(configuration.isPressed ? Theme.accentHover : color))
            .shadow(color: color.opacity(enabled ? 0.35 : 0), radius: 10, y: 4)
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

/// Every other button: a light card with a border.
struct SecondaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.ink
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 13).padding(.vertical, 7)
            .foregroundStyle(tint)
            .background(RoundedRectangle(cornerRadius: Theme.radius)
                .fill(configuration.isPressed ? Theme.surface3 : Theme.surface2))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.borderStrong))
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
    static var danger: PrimaryButtonStyle { PrimaryButtonStyle(color: Theme.danger) }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

/// A quiet status label: soft background, coloured text.
struct Pill: View {
    let text: String
    var color: Color = Theme.accentText
    var background: Color = Theme.accentSoft

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .padding(.horizontal, 7).padding(.vertical, 2.5)
            .background(Capsule().fill(background))
            .foregroundStyle(color)
    }
}
