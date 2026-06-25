import SwiftUI

// MARK: - Skeleton shimmer
//
// GitHub-style loading placeholders: soft rounded fills with an animated highlight
// that sweeps diagonally left-to-right on a repeating loop. Used on the very first
// app load while the initial data is still hydrating, then crossfaded out to the real
// content. Honors Reduce Motion (static placeholders, no sweep) so it never animates
// for users who have opted out.

// MARK: - Shimmer modifier

extension View {
    /// Overlay an animated diagonal highlight sweep onto the view's shape, masked to
    /// the view's own bounds. Apply to placeholder fills (e.g. `SkeletonBlock`). With
    /// Reduce Motion on, the sweep is omitted and only the static base fill shows.
    func shimmer() -> some View {
        modifier(ShimmerModifier())
    }
}

private struct ShimmerModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Drives the sweep from off-screen-left to off-screen-right and loops.
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay {
                if !reduceMotion {
                    GeometryReader { geo in
                        // A soft white band, rotated and translated across the width so it
                        // reads as a diagonal glint passing over the placeholder.
                        let width = geo.size.width
                        LinearGradient(
                            colors: [.clear, Color.white.opacity(0.35), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: width * 0.6)
                        .offset(x: phase * width * 1.6)
                        .rotationEffect(.degrees(18))
                    }
                    .blendMode(.plusLighter)
                    .mask(content)
                    .allowsHitTesting(false)
                }
            }
            // Repeating sweep, ~1.4s per pass with a small idle gap at the end of each loop.
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.4).delay(0.1).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

// MARK: - Skeleton block
//
// One rounded placeholder rectangle (the building block for skeleton layouts). The
// hairline fill matches the app's `Theme.hairFill`, and the shimmer sweep rides on top.

struct SkeletonBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat
    var cornerRadius: CGFloat = Theme.radiusSmall

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Theme.hairFill)
            .frame(width: width, height: height)
            .shimmer()
    }
}

// MARK: - Skeleton card
//
// A full-width card-shaped placeholder matching the app's GroupBox chrome (fill,
// hairline, radius, 20pt padding), with caller-supplied skeleton content inside. Used
// so skeleton cards line up with the real cards they stand in for.

struct SkeletonCard<Content: View>: View {
    var padding: CGFloat = Theme.cardPadding
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 1)
            )
    }
}
