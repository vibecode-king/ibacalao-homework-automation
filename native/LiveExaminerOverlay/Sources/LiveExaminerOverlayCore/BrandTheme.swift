import SwiftUI
import AppKit

/// iBacalao tokens — restrained: lime only for primary CTAs, not every label.
enum Brand {
    static let ground = Color(hex: 0x0F1110)
    static let card = Color(hex: 0x16191A)
    static let skeleton = Color(hex: 0x1B1F20)
    static let active = Color(hex: 0x202525)
    static let raised = Color(hex: 0x282D2E)

    static let hairline = Color(hex: 0x272C2D)
    static let edge = Color(hex: 0x3A4042)

    static let bright = Color(hex: 0xF1F4F3)
    static let body = Color(hex: 0xC9D0D1)
    static let secondary = Color(hex: 0xA9B1B3)
    static let muted = Color(hex: 0x8B9395)
    static let faint = Color(hex: 0x6A7173)

    /// Primary CTA fill only — do not splash on labels / pills / rings.
    static let accent = Color(hex: 0xB4FF39)
    static let accentHover = Color(hex: 0x9BE81F)
    static let accentTeal = Color(hex: 0xCCFF33)
    static let accentBright = Color(hex: 0xD4FF5C)
    static let onAccent = Color(hex: 0x0C1400)

    static let success = Color(hex: 0x5FD07A)
    static let warning = Color(hex: 0xE0B13A)
    static let danger = Color(hex: 0xF0685C)
    static let info = Color(hex: 0x5FB0E0)

    static let cornerSm: CGFloat = 4
    static let cornerMd: CGFloat = 6
    static let cornerLg: CGFloat = 8
}

enum BrandFont {
    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    static func mono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

struct BrandPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BrandFont.body(13, weight: .semibold))
            .foregroundStyle(Brand.onAccent)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(isEnabled ? (configuration.isPressed ? Brand.accentHover : Brand.accent) : Brand.raised)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .opacity(isEnabled ? 1 : 0.5)
    }
}

struct BrandLargePrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BrandFont.display(16, weight: .semibold))
            .foregroundStyle(Brand.onAccent)
            .tracking(-0.3)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(isEnabled ? (configuration.isPressed ? Brand.accentHover : Brand.accent) : Brand.raised)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .opacity(isEnabled ? 1 : 0.5)
    }
}

/// Liquid-glass green CTA — frosted lime fill with soft highlight.
struct BrandLiquidGlassButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BrandFont.display(16, weight: .semibold))
            .foregroundStyle(Brand.onAccent)
            .tracking(-0.3)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Brand.accent.opacity(configuration.isPressed ? 0.75 : 0.92),
                                    Brand.accentHover.opacity(configuration.isPressed ? 0.65 : 0.8),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.45), Brand.accent.opacity(0.2)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
            }
            .shadow(color: Brand.accent.opacity(0.25), radius: configuration.isPressed ? 4 : 12, y: 4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(isEnabled ? 1 : 0.5)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct BrandGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(BrandFont.body(13, weight: .medium))
            .foregroundStyle(configuration.isPressed ? Brand.bright : Brand.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(configuration.isPressed ? Brand.edge : Brand.hairline, lineWidth: 1)
            )
    }
}

/// Frosted glass field for the overlay chat bar (not opaque card).
struct BrandGlassChatField: View {
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void
    @FocusState.Binding var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(BrandFont.body(13))
                .foregroundStyle(Brand.bright)
                .focused($focused)
                .onSubmit(onSubmit)

            Button(action: onSubmit) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Brand.onAccent)
                    .frame(width: 28, height: 28)
                    .background {
                        Circle()
                            .fill(.ultraThinMaterial)
                        Circle()
                            .fill(Brand.accent.opacity(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.35 : 0.95))
                        Circle()
                            .stroke(Color.white.opacity(0.35), lineWidth: 0.8)
                    }
            }
            .buttonStyle(.plain)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background {
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.08))
            Capsule(style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.4), Color.white.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
    }
}

/// Wordmark — prefers app Resources, then SPM module bundle.
struct BrandLogo: View {
    var height: CGFloat = 36

    var body: some View {
        Group {
            if let image = Self.loadLogo() {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(height: height)
            } else {
                HStack(spacing: 0) {
                    Text("i")
                        .foregroundStyle(Brand.accent)
                    Text("bacalao")
                        .foregroundStyle(Brand.bright)
                }
                .font(BrandFont.display(height * 0.55, weight: .semibold))
            }
        }
        .accessibilityLabel("iBacalao")
    }

    private static func loadLogo() -> NSImage? {
        // SwiftPM's generated resource-bundle accessor fatalErrors if its
        // .bundle isn't shipped inside the .app — build_app.sh /
        // release_digital.sh copy logo.png straight into Contents/Resources
        // instead, so that .bundle never exists in a built app. Do not
        // reference that accessor here; Bundle.main is the only real lookup.
        let mainCandidates: [URL?] = [
            Bundle.main.url(forResource: "logo", withExtension: "png"),
            Bundle.main.resourceURL?.appendingPathComponent("logo.png"),
        ]
        for case let url? in mainCandidates {
            if let img = NSImage(contentsOf: url) { return img }
        }
        return nil
    }
}

/// Form field per DESIGN.md: card fill + hairline (not white neon outline).
struct BrandOutlinedFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .font(BrandFont.body(13))
            .foregroundStyle(Brand.bright)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Brand.card)
            .overlay(
                RoundedRectangle(cornerRadius: Brand.cornerMd)
                    .stroke(Brand.hairline, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Brand.cornerMd))
    }
}

/// Quiet segment control — selected = raised surface, not lime fill.
struct BrandPillSelector<Option: Hashable & Identifiable>: View where Option: CustomStringConvertible {
    let options: [Option]
    @Binding var selection: Option

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                let selected = selection == option
                Button {
                    selection = option
                } label: {
                    Text(option.description)
                        .font(BrandFont.body(12, weight: .medium))
                        .foregroundStyle(selected ? Brand.bright : Brand.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(selected ? Brand.active : Color.clear)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Brand.card)
        .overlay(RoundedRectangle(cornerRadius: Brand.cornerMd).stroke(Brand.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Brand.cornerMd))
    }
}

/// Custom dropdown — branded card list, not the native macOS menu.
struct BrandDropdownSelector<Option: Identifiable & Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    var emoji: (Option) -> String
    var title: (Option) -> String
    var subtitle: ((Option) -> String)? = nil
    var isEnabled: Bool = true
    var maxListHeight: CGFloat = 280

    @State private var isOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                guard isEnabled else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    isOpen.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Text(emoji(selection))
                        .font(.system(size: 15))
                        .frame(width: 22, alignment: .center)
                    Text(title(selection))
                        .font(BrandFont.body(13, weight: .medium))
                        .foregroundStyle(isEnabled ? Brand.bright : Brand.faint)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Brand.muted)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Brand.card)
                .overlay(
                    RoundedRectangle(cornerRadius: Brand.cornerMd)
                        .stroke(isOpen ? Brand.accentTeal.opacity(0.7) : Brand.hairline, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: Brand.cornerMd))
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)

            if isOpen {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                            let selected = option == selection
                            Button {
                                selection = option
                                withAnimation(.easeIn(duration: 0.12)) {
                                    isOpen = false
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    Text(emoji(option))
                                        .font(.system(size: 15))
                                        .frame(width: 22, alignment: .center)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(title(option))
                                            .font(BrandFont.body(13, weight: selected ? .semibold : .regular))
                                            .foregroundStyle(Brand.bright)
                                            .lineLimit(1)
                                        if let subtitle, !subtitle(option).isEmpty {
                                            Text(subtitle(option))
                                                .font(BrandFont.mono(10))
                                                .foregroundStyle(Brand.faint)
                                        }
                                    }
                                    Spacer(minLength: 8)
                                    if selected {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundStyle(Brand.accent)
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(selected ? Brand.active : Color.clear)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if index < options.count - 1 {
                                Rectangle()
                                    .fill(Brand.hairline)
                                    .frame(height: 1)
                                    .padding(.leading, 44)
                            }
                        }
                    }
                }
                .frame(maxHeight: maxListHeight)
                .background(Brand.card)
                .overlay(
                    RoundedRectangle(cornerRadius: Brand.cornerMd)
                        .stroke(Brand.hairline, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: Brand.cornerMd))
                .padding(.top, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onChange(of: selection) { _, _ in
            if isOpen {
                withAnimation(.easeIn(duration: 0.12)) { isOpen = false }
            }
        }
    }
}

struct BrandBoolPillSelector: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center) {
            Text(title)
                .font(BrandFont.body(13, weight: .medium))
                .foregroundStyle(Brand.body)
            Spacer(minLength: 12)
            BrandModernToggle(isOn: $isOn)
        }
    }
}

/// Contemporary switch — ON = thumb on the right, lime track (no chrome).
struct BrandModernToggle: View {
    @Binding var isOn: Bool

    private let width: CGFloat = 52
    private let height: CGFloat = 30
    private let thumb: CGFloat = 24

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                isOn.toggle()
            }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Brand.accent : Brand.active)
                    .overlay(
                        Capsule()
                            .stroke(isOn ? Brand.accent.opacity(0.01) : Brand.edge, lineWidth: 1)
                    )

                Circle()
                    .fill(isOn ? Brand.onAccent : Brand.bright)
                    .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                    .frame(width: thumb, height: thumb)
                    .padding(3)
            }
            .frame(width: width, height: height)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Speak tips aloud")
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// Centered big % + green progress line at ~90% of available width.
struct UsageRemainingBar: View {
    var fraction: Double
    var percentLabel: Int
    /// When false, show a muted placeholder instead of a fake 100%.
    var isActive: Bool = true
    var inactiveTitle: String = "—"

    var body: some View {
        VStack(spacing: 14) {
            Text(isActive ? "\(percentLabel)%" : inactiveTitle)
                .font(BrandFont.display(40, weight: .semibold))
                .foregroundStyle(isActive ? Brand.bright : Brand.muted)
                .tracking(-1)
                .frame(maxWidth: .infinity)

            GeometryReader { geo in
                let trackWidth = geo.size.width * 0.9
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Brand.hairline)
                        .frame(width: trackWidth, height: 4)
                    if isActive {
                        Capsule()
                            .fill(Brand.accent)
                            .frame(
                                width: max(4, trackWidth * max(0, min(1, fraction))),
                                height: 4
                            )
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(height: 4)
        }
        .accessibilityLabel(
            isActive
                ? "\(percentLabel) percent API credits remaining"
                : inactiveTitle
        )
    }
}

private extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}
