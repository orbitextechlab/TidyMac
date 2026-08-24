import SwiftUI

// MARK: - Building blocks

extension View {
    /// Quiet chip surface: soft fill with a hairline border. (Named neuRaised
    /// historically; the name survives across restyles.)
    func neuRaised(_ cornerRadius: CGFloat = 10) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Theme.chipFill)
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Theme.border, lineWidth: 1)
                )
        )
    }
}

/// Standard card: flat fill with a hairline border.
struct GlassCard<Content: View>: View {
    var padding: CGFloat = 16
    /// Opt out for hero-sized cards where a hover lift would feel jumpy.
    var hoverLift: Bool = false

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(hovering ? Theme.cardHover : Theme.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .strokeBorder(Theme.border, lineWidth: 1)
                    )
            )
            .offset(y: hovering && !reduceMotion ? -1 : 0)
            .onHover { inside in
                guard hoverLift else { return }
                withAnimation(reduceMotion ? nil : Theme.Motion.snappy) { hovering = inside }
            }
    }
}

/// Press acknowledgment for card-like buttons: a quick, tiny sink. Shared so
/// every clickable tile in the app answers a press the same way.
struct PressableCardStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(reduceMotion ? nil : Theme.Motion.press, value: configuration.isPressed)
    }
}

/// Small pill chip used for tactile value readouts ("43%", "2316 RPM").
struct NeuValueChip: View {
    let text: String
    var font: Font = .system(size: 12, weight: .semibold)
    var color: Color = .primary

    var body: some View {
        Text(text)
            .font(font)
            .monospacedDigit()
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .neuRaised(7)
    }
}

/// Staggered entrance: content fades in and rises, delayed by its `index` so
/// a column of cards cascades instead of popping in at once.
private struct StaggeredEntrance: ViewModifier {
    let index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : (reduceMotion ? 0 : 16))
            .onAppear {
                // Decorative cascade — under Reduce Motion content just appears.
                if reduceMotion {
                    shown = true
                } else {
                    withAnimation(Theme.Motion.gentle
                        .delay(Double(index) * 0.07)) { shown = true }
                }
            }
    }
}

extension View {
    func staggeredEntrance(_ index: Int) -> some View {
        modifier(StaggeredEntrance(index: index))
    }
}

// MARK: - Cards

/// Compact statistic tile: uppercase label, bold value, detail, slim meter.
struct StatTile: View {
    let label: String
    let value: String
    var valueColor: Color = .primary
    var detail: String? = nil
    var detailColor: Color = .secondary
    var fraction: Double? = nil
    var fillColor: Color = Theme.neutralFill
    /// Smaller variant for tight places such as the menu bar popover.
    var compact: Bool = false

    var body: some View {
        GlassCard(padding: compact ? 11 : 15) {
            VStack(alignment: .leading, spacing: compact ? 2 : 3) {
                Text(label.uppercased())
                    .font(.system(size: compact ? 9.5 : 10.5, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                    .tracking(0.8)
                // No numeric content transition here: these tiles change on
                // every poll, and morphing glyphs four times a screen keeps the
                // CPU rasterising text instead of idling.
                Text(value)
                    .font(.system(size: compact ? 19 : 21, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(valueColor)
                if let detail {
                    Text(detail)
                        .font(.system(size: compact ? 10.5 : 11.5))
                        .foregroundStyle(detailColor)
                }
                if let fraction {
                    Meter(fraction: fraction, color: fillColor, height: 4)
                        .padding(.top, compact ? 5 : 7)
                }
            }
        }
    }
}

/// Meter: quiet track with a glowing gradient fill.
struct Meter: View {
    let fraction: Double
    var color: Color = Theme.accent
    var height: CGFloat = 8

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Theme.track)
            // Full-width bar squeezed with scaleEffect, and deliberately not
            // animated. Measured: sliding these bars for half a second on every
            // two-second poll kept the app at ~10% CPU with 24% spikes, because
            // each frame re-rendered the gradient and its glow. Snapping to the
            // new value costs 0–4% and, at a two-second cadence, reads fine.
            Capsule()
                .fill(LinearGradient(colors: [color.opacity(0.45), color],
                                     startPoint: .leading, endPoint: .trailing))
                .shadow(color: color.opacity(0.35), radius: 5)
                .scaleEffect(x: max(0.001, min(1, fraction)), anchor: .leading)
                .opacity(fraction > 0.005 ? 1 : 0)
        }
        .frame(height: height)
    }
}

/// Labeled meter row: name, glowing bar, value chip on the right.
struct MeterRow: View {
    let label: String
    let value: String
    let fraction: Double
    var color: Color = Theme.accent

    var body: some View {
        HStack(spacing: 14) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 110, alignment: .leading)
            Meter(fraction: fraction, color: color)
            NeuValueChip(text: value, font: .system(size: 11.5, weight: .semibold))
                .frame(width: 74, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }
}

/// Section header — small uppercase tracked label.
struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(.sectionHeader)
            .foregroundStyle(Theme.textMuted)
            .tracking(0.9)
            .padding(.top, 8)
    }
}

/// A key/value line used inside detail cards.
struct InfoRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.system(size: 12))
    }
}

// MARK: - Loading & progress

/// Rotating arc spinner — the app-wide "working" indicator.
struct SpinnerRing: View {
    var size: CGFloat = 18
    var lineWidth: CGFloat = 2.5
    var color: Color = Theme.accent

    @State private var spinning = false

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.22), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: 0.28)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(spinning ? 360 : 0))
                // Progress signal — keeps spinning under Reduce Motion, the
                // way the system's own indeterminate indicator does.
                .animation(Theme.Motion.spinner, value: spinning)
        }
        .frame(width: size, height: size)
        .onAppear { spinning = true }
    }
}

/// Progress banner shown while a scan runs: spinner, title, live status line,
/// and an accent running total on the right.
struct ScanBanner: View {
    let title: String
    var status: String = ""
    var found: String? = nil

    var body: some View {
        GlassCard(padding: 15) {
            HStack(spacing: 12) {
                SpinnerRing()
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    if !status.isEmpty {
                        Text(status)
                            .font(.system(size: 11.5))
                            .monospacedDigit()
                            .foregroundStyle(Theme.textSecondary)
                            .contentTransition(.numericText())
                    }
                }
                Spacer()
                if let found {
                    Text(found)
                        .font(.system(size: 13, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.accent)
                        .contentTransition(.numericText())
                }
            }
        }
    }
}

/// One shimmering placeholder block. The moving highlight is driven by a
/// shared phase so all blocks in a list sweep together.
struct ShimmerBlock: View {
    var width: CGFloat? = nil
    var height: CGFloat = 10
    var radius: CGFloat = 5

    @State private var phase: CGFloat = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.primary.opacity(0.05))
            .overlay(
                GeometryReader { geo in
                    LinearGradient(colors: [.clear, Color.primary.opacity(0.07), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 1.6)
                        .offset(x: phase * geo.size.width * 1.6)
                }
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            )
            .frame(width: width, height: height)
            .onAppear {
                // Decorative shimmer — the static skeleton block is enough
                // under Reduce Motion.
                guard !reduceMotion else { return }
                withAnimation(Theme.Motion.shimmer) { phase = 1 }
            }
    }
}

/// Skeleton result list shown while scanning — shimmer stand-ins for the rows
/// that are about to appear.
struct SkeletonList: View {
    var rows: Int = 6

    var body: some View {
        GlassCard(padding: 0) {
            VStack(spacing: 0) {
                ForEach(0..<rows, id: \.self) { i in
                    HStack(spacing: 13) {
                        ShimmerBlock(width: 18, height: 18, radius: 5)
                        ShimmerBlock(width: 30, height: 30, radius: 8)
                        VStack(alignment: .leading, spacing: 7) {
                            ShimmerBlock(height: 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.trailing, i.isMultiple(of: 2) ? 220 : 260)
                            ShimmerBlock(height: 8, radius: 4)
                                .padding(.trailing, i.isMultiple(of: 2) ? 90 : 130)
                        }
                        ShimmerBlock(width: 56, height: 12, radius: 6)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    if i < rows - 1 {
                        Divider().opacity(0.5)
                    }
                }
            }
        }
    }
}

/// Indeterminate slim progress bar — a soft accent pulse sweeping the track.
struct IndeterminateBar: View {
    var height: CGFloat = 4
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule()
                    .fill(LinearGradient(colors: [Theme.accent.opacity(0), Theme.accent,
                                                  Theme.accent.opacity(0)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * 0.45)
                    .offset(x: phase * geo.size.width)
            }
        }
        .frame(height: height)
        .clipShape(Capsule())
        .onAppear {
            // Progress signal — the sweep is the only "still working" cue on
            // this bar, so it keeps moving under Reduce Motion.
            withAnimation(Theme.Motion.progressSweep) { phase = 1 }
        }
    }
}
