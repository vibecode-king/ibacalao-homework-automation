import SwiftUI

/// Inline annotation for a single weak sentence: the quote, a margin note that grows out of
/// it (label, criterion, feedback, CTA), and a same-place before/after swap on "Fix it" —
/// never a full-screen replace.
struct SentenceFixCard: View {
    let tip: TipResult
    let fix: (quote: String, revision: String)

    @State private var noteRevealed = false
    @State private var isFixed = false

    init(tip: TipResult, fix: (quote: String, revision: String)) {
        self.tip = tip
        self.fix = fix
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isFixed ? fix.revision : fix.quote)
                .font(BrandFont.body(13, weight: .medium))
                .foregroundStyle(Brand.bright)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background((isFixed ? Brand.success : Brand.warning).opacity(0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: Brand.cornerMd)
                        .stroke((isFixed ? Brand.success : Brand.warning).opacity(0.4), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: Brand.cornerMd))
                .fixedSize(horizontal: false, vertical: true)
                .id(isFixed ? "revision" : "quote")
                .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))

            if noteRevealed {
                marginNote
                    .transition(
                        .opacity
                            .combined(with: .move(edge: .top))
                            .combined(with: .scale(scale: 0.92, anchor: .top))
                    )
            }
        }
        .padding(12)
        .background(Brand.active)
        .clipShape(RoundedRectangle(cornerRadius: Brand.cornerLg))
        .onAppear {
            withAnimation(.easeOut(duration: 0.28).delay(0.12)) {
                noteRevealed = true
            }
        }
    }


    private var marginNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("FIRST THING I'D FIX")
                .font(BrandFont.mono(10, weight: .semibold))
                .foregroundStyle(Brand.warning)
                .tracking(0.8)
            Text(tip.section.uppercased())
                .font(BrandFont.mono(9))
                .foregroundStyle(Brand.faint)
                .tracking(0.6)
            Text(tip.problem)
                .font(BrandFont.body(12))
                .foregroundStyle(Brand.body)
                .fixedSize(horizontal: false, vertical: true)

            if isFixed {
                Text("FIXED")
                    .font(BrandFont.mono(10, weight: .semibold))
                    .foregroundStyle(Brand.success)
                    .tracking(0.8)
            } else {
                Button {
                    withAnimation(.easeInOut(duration: 0.24)) {
                        isFixed = true
                    }
                } label: {
                    Text("FIX IT")
                        .font(BrandFont.body(11, weight: .semibold))
                        .foregroundStyle(Brand.onAccent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Brand.accent)
                        .clipShape(RoundedRectangle(cornerRadius: Brand.cornerSm))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Replace the highlighted sentence with the suggested revision")
            }
        }
        .padding(.leading, 10)
        .overlay(alignment: .leading) {
            Rectangle().fill(Brand.warning.opacity(0.4)).frame(width: 2)
        }
    }
}
