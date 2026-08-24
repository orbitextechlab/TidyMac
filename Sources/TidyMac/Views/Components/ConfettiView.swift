import SwiftUI

/// One-shot celebratory confetti burst: a `Canvas` + `TimelineView` particle
/// system with mixed shapes (discs, streamers, rings), a radial explosion
/// that decelerates into gentle gravity, per-particle tumble, and a fade-out.
///
/// Fire by incrementing `burst` — each change plays one burst that unmounts
/// itself when finished, so nothing keeps rendering after the show. Under
/// Reduce Motion this view draws nothing at all; callers pair the burst with
/// `Haptics.successWithSound()`, whose chime stands in for the confetti.
///
/// Particle-system approach adapted from PureMac
/// (https://github.com/momenbasel/PureMac), © PureMac Contributors,
/// MIT License. See NOTICE.
struct ConfettiView: View {
    /// Increment to fire one burst.
    let burst: Int
    /// Where the explosion originates, in unit coordinates of this view.
    var origin: UnitPoint = .center

    @State private var startedAt: Date?
    @State private var particles: [Particle] = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let lifetime: TimeInterval = 1.8
    private static let count = 110

    private struct Particle {
        let angle: Double      // launch direction (radians)
        let speed: Double      // burst radius contribution (points)
        let size: CGFloat
        let color: Color
        let spin: Double       // tumble rate (radians/second)
        let drift: Double      // sideways sway
        let shape: Int         // 0 disc, 1 streamer, 2 ring
    }

    // Sweep palette: accent oranges, the success green, warm paper tones.
    private static let palette: [Color] = [
        Theme.accent,
        Color(red: 1.0, green: 0.82, blue: 0.55),
        Color(red: 0.85, green: 0.42, blue: 0.15),
        Theme.ok,
        Color(red: 1.0, green: 0.94, blue: 0.83),
    ]

    var body: some View {
        Group {
            if let start = startedAt, !reduceMotion {
                TimelineView(.animation) { timeline in
                    Canvas { ctx, size in
                        let t = timeline.date.timeIntervalSince(start)
                        guard t >= 0, t < Self.lifetime else { return }
                        let progress = t / Self.lifetime
                        let o = CGPoint(x: origin.x * size.width,
                                        y: origin.y * size.height)
                        // Explosion decelerates (cubic ease-out) while gravity
                        // quadratically takes over — reads as "pop, then fall".
                        let radial = 1 - pow(1 - progress, 3)
                        let fall = 210 * t * t
                        let alpha = progress < 0.65 ? 1.0 : max(0, 1 - (progress - 0.65) / 0.35)

                        for p in particles {
                            let pos = CGPoint(
                                x: o.x + CoreGraphics.cos(p.angle) * p.speed * radial + p.drift * t * 40,
                                y: o.y + CoreGraphics.sin(p.angle) * p.speed * radial + fall)
                            var layer = ctx
                            layer.opacity = alpha
                            layer.translateBy(x: pos.x, y: pos.y)
                            layer.rotate(by: .radians(p.spin * t))
                            let rect = CGRect(x: -p.size / 2, y: -p.size / 2,
                                              width: p.size, height: p.size)
                            switch p.shape {
                            case 1:
                                // Streamer: tall thin rectangle that tumbles.
                                layer.fill(Path(CGRect(x: -p.size / 4, y: -p.size / 2,
                                                       width: p.size / 2, height: p.size)),
                                           with: .color(p.color))
                            case 2:
                                layer.stroke(Path(ellipseIn: rect),
                                             with: .color(p.color), lineWidth: 1.6)
                            default:
                                layer.fill(Path(ellipseIn: rect), with: .color(p.color))
                            }
                        }
                    }
                }
                .allowsHitTesting(false)
            }
        }
        .onChange(of: burst) {
            guard burst > 0, !reduceMotion else { return }
            particles = Self.makeParticles()
            startedAt = Date()
            // Unmount once the show ends so the TimelineView stops ticking.
            let generation = startedAt
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.lifetime + 0.1) {
                if startedAt == generation { startedAt = nil }
            }
        }
    }

    private static func makeParticles() -> [Particle] {
        (0..<count).map { _ in
            Particle(angle: .random(in: 0..<(2 * .pi)),
                     speed: .random(in: 40...170),
                     size: .random(in: 4...9),
                     color: palette.randomElement()!,
                     spin: .random(in: -7...7),
                     drift: .random(in: -1...1),
                     shape: Int.random(in: 0...2))
        }
    }
}
