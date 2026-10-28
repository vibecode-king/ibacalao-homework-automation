import AppKit

/// Paints the lime+black squircle into a Dock tile. Used by the Dock plugin
/// (app quit) and by the running app so Tinted/Dark cannot recolor it.
enum DockTilePainter {
    static func apply(to tile: NSDockTile, bundle: Bundle) {
        guard
            let url = bundle.url(forResource: "AppIconDock", withExtension: "png"),
            let image = NSImage(contentsOf: url)
        else { return }
        image.isTemplate = false
        let view = NSImageView(frame: NSRect(origin: .zero, size: tile.size))
        view.image = image
        view.imageScaling = .scaleProportionallyUpOrDown
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        tile.contentView = view
        tile.display()
    }
}

@objc(iBacalaoDockTilePlugin)
final class iBacalaoDockTilePlugin: NSObject, NSDockTilePlugIn {
    func setDockTile(_ dockTile: NSDockTile?) {
        guard let dockTile else { return }
        DockTilePainter.apply(to: dockTile, bundle: Bundle(for: iBacalaoDockTilePlugin.self))
    }
}
