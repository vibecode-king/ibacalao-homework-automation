import SwiftUI
import AppKit
import ObjectiveC

/// Real system glass behind the overlay.
///
/// On macOS 26+ uses `NSGlassEffectView` (Apple Liquid Glass) via runtime lookup
/// so we still compile against older SDKs. Older systems fall back to
/// `NSVisualEffectView` with behind-window blur — never a solid fill.
struct GlassBackground: NSViewRepresentable {
    var cornerRadius: CGFloat = 20

    func makeNSView(context: Context) -> NSView {
        Self.makeGlassView(cornerRadius: cornerRadius)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.wantsLayer = true
        nsView.layer?.cornerRadius = cornerRadius
        nsView.layer?.masksToBounds = true
        if let glass = nsView as? NSVisualEffectView {
            glass.state = .active
        }
    }

    static func makeGlassView(cornerRadius: CGFloat) -> NSView {
        // Prefer Apple’s Liquid Glass host when the OS provides it (macOS 26+).
        if let glassClass = NSClassFromString("NSGlassEffectView") as? NSView.Type {
            let glass = glassClass.init(frame: .zero)
            glass.wantsLayer = true
            glass.layer?.cornerRadius = cornerRadius
            glass.layer?.masksToBounds = true
            if glass.responds(to: Selector(("setCornerRadius:"))) {
                glass.setValue(cornerRadius, forKey: "cornerRadius")
            }
            dlog("[Glass] using NSGlassEffectView (Liquid Glass)")
            return glass
        }

        dlog("[Glass] NSGlassEffectView unavailable — NSVisualEffectView fallback")
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = cornerRadius
        effect.layer?.masksToBounds = true
        // Emphasize refraction-like edge on pre-Liquid-Glass macOS.
        effect.appearance = NSAppearance(named: .vibrantDark)
        return effect
    }
}

/// Hosts SwiftUI content inside Apple Liquid Glass when available.
final class LiquidGlassHostingView<Content: View>: NSView {
    private let glassHost: NSView
    private let hosting: NSHostingView<Content>
    private let cornerRadius: CGFloat

    init(rootView: Content, cornerRadius: CGFloat = 20) {
        self.cornerRadius = cornerRadius
        self.glassHost = GlassBackground.makeGlassView(cornerRadius: cornerRadius)
        self.hosting = NSHostingView(rootView: rootView)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = cornerRadius
        layer?.masksToBounds = true

        glassHost.translatesAutoresizingMaskIntoConstraints = false
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.sizingOptions = []

        addSubview(glassHost)

        // NSGlassEffectView wants content in `contentView`; VisualEffect uses a subview.
        if NSStringFromClass(type(of: glassHost)).contains("GlassEffect"),
           glassHost.responds(to: Selector(("setContentView:"))) {
            glassHost.setValue(hosting, forKey: "contentView")
        } else {
            glassHost.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: glassHost.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: glassHost.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: glassHost.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: glassHost.bottomAnchor),
            ])
        }

        NSLayoutConstraint.activate([
            glassHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            glassHost.topAnchor.constraint(equalTo: topAnchor),
            glassHost.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        // NSGlassEffectView can swallow hits; prefer the SwiftUI hosting layer.
        let local = convert(point, to: hosting)
        if hosting.bounds.contains(local) {
            if let hit = hosting.hitTest(local) { return hit }
            return hosting
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        super.mouseDown(with: event)
    }

    func setRootView(_ rootView: Content) {
        hosting.rootView = rootView
    }
}
