"""DMG background: solid light fill (#f1f4f3, the 'bright' token) with the
mark-only logo and the three-chevron install arrow."""
from PIL import Image, ImageDraw

# Canvas is deliberately much larger than the requested 660x460 window —
# Finder anchors a background picture at the window's top-left and leaves
# anything beyond the image's edges plain white. If Finder ever opens the
# window bigger than we asked (observed happening on a fresh volume before
# .DS_Store settles, and could differ across machines/displays), a
# same-size image runs out and shows a white gap. This margin means the
# solid fill still covers the visible area even then.
W, H = 1800, 1200
BG = (201, 208, 209)          # #c9d0d1 — body token, used as bg here
BLACK = (12, 20, 0)           # #0c1400 — onAccent

LOGO = "/Users/joaquin/Documents/iBacalao/native/LiveExaminerOverlay/dmg-assets/logo_black.png"
OUT = "/Users/joaquin/Documents/iBacalao/native/LiveExaminerOverlay/dmg-assets/background.png"

# Finder always anchors the background picture's top-left at the window's
# top-left, regardless of how much bigger the image is than the window. So
# logo/arrow must stay positioned relative to the originally-requested
# 660x460 visible window, NOT centered against the oversized W/H canvas —
# centering against the full canvas pushes them far outside what's ever
# actually visible.
VISIBLE_W, VISIBLE_H = 660, 460
ICON_Y = 230  # matches the icon row position set in build_styled_dmg.sh


def main():
    canvas = Image.new("RGBA", (W, H), (*BG, 255))

    # Three-chevron install arrow, black, between the two icon slots.
    chev_w, chev_h = 220, 90
    layer = Image.new("RGBA", (chev_w, chev_h), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    cy = chev_h // 2
    step, size = 60, 42
    for i in range(3):
        cx = 45 + i * step
        d.line([(cx - size // 2, cy - size // 2), (cx + size // 2, cy),
                (cx - size // 2, cy + size // 2)],
               fill=(*BLACK, 255), width=10, joint="curve")
    canvas.alpha_composite(layer, ((VISIBLE_W - chev_w) // 2, ICON_Y - chev_h // 2))

    # Full logo lockup (mark + wordmark), centered at the top of the visible
    # window area (not the oversized canvas — see note above).
    logo = Image.open(LOGO).convert("RGBA")
    logo_w = 260
    logo_h = int(logo_w * logo.height / logo.width)
    logo = logo.resize((logo_w, logo_h), Image.LANCZOS)
    canvas.alpha_composite(logo, ((VISIBLE_W - logo_w) // 2, 40))

    canvas.convert("RGB").save(OUT)
    print(f"Wrote {OUT} ({W}x{H})")


if __name__ == "__main__":
    main()
