import SwiftUI

/// The sensor-based rule drawn as a ramp: flat at the fan's minimum up to
/// `minTemp`, rising to full speed at `maxTemp`, flat above it. Both corner
/// points are draggable, and the live temperature rides along the line.
struct FanRampChart: View {
    @Binding var minTemp: Double
    @Binding var maxTemp: Double
    let currentTemp: Double?
    let minRPM: Double
    let maxRPM: Double
    /// Called when a drag ends, so the caller can push the change to hardware.
    var onCommit: () -> Void = {}

    /// Temperature window drawn on the x axis.
    private let lo: Double = 30
    private let hi: Double = 105
    /// Keep the two handles from crossing or collapsing onto each other.
    private let minSpan: Double = 5

    @State private var dragging: Handle?

    private enum Handle { case low, high }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height - 18      // leave room for the axis labels
            let lowX = x(minTemp, in: w)
            let highX = x(maxTemp, in: w)

            ZStack(alignment: .topLeading) {
                gridLines(w: w, h: h)
                rampArea(lowX: lowX, highX: highX, w: w, h: h)
                rampLine(lowX: lowX, highX: highX, w: w, h: h)
                if let currentTemp { liveMarker(temp: currentTemp, w: w, h: h) }
                handle(at: CGPoint(x: lowX, y: h), kind: .low)
                handle(at: CGPoint(x: highX, y: 0), kind: .high)
                axisLabels(w: w, h: h)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let handle = dragging ?? nearestHandle(to: value.startLocation.x,
                                                               lowX: lowX, highX: highX)
                        dragging = handle
                        let temp = temperature(atX: value.location.x, in: w)
                        switch handle {
                        case .low: minTemp = min(max(lo, temp), maxTemp - minSpan)
                        case .high: maxTemp = max(min(hi, temp), minTemp + minSpan)
                        }
                    }
                    .onEnded { _ in
                        dragging = nil
                        onCommit()
                    }
            )
        }
        .frame(height: 150)
    }

    // MARK: - Geometry

    private func x(_ temp: Double, in width: CGFloat) -> CGFloat {
        CGFloat((min(hi, max(lo, temp)) - lo) / (hi - lo)) * width
    }

    private func temperature(atX px: CGFloat, in width: CGFloat) -> Double {
        guard width > 0 else { return lo }
        return lo + Double(min(width, max(0, px)) / width) * (hi - lo)
    }

    private func nearestHandle(to px: CGFloat, lowX: CGFloat, highX: CGFloat) -> Handle {
        abs(px - lowX) <= abs(px - highX) ? .low : .high
    }

    /// Ramp outline: bottom-left → low corner → high corner → top-right.
    private func rampPath(lowX: CGFloat, highX: CGFloat, w: CGFloat, h: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: h))
        path.addLine(to: CGPoint(x: lowX, y: h))
        path.addLine(to: CGPoint(x: highX, y: 0))
        path.addLine(to: CGPoint(x: w, y: 0))
        return path
    }

    // MARK: - Layers

    private func gridLines(w: CGFloat, h: CGFloat) -> some View {
        ForEach([0.0, 0.5, 1.0], id: \.self) { fraction in
            Rectangle()
                .fill(Theme.border)
                .frame(height: 1)
                .offset(y: h * CGFloat(1 - fraction))
        }
    }

    private func rampArea(lowX: CGFloat, highX: CGFloat, w: CGFloat, h: CGFloat) -> some View {
        var area = rampPath(lowX: lowX, highX: highX, w: w, h: h)
        area.addLine(to: CGPoint(x: w, y: h))
        area.closeSubpath()
        return area.fill(
            LinearGradient(colors: [Theme.accent.opacity(0.32), Theme.accent.opacity(0.02)],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    private func rampLine(lowX: CGFloat, highX: CGFloat, w: CGFloat, h: CGFloat) -> some View {
        rampPath(lowX: lowX, highX: highX, w: w, h: h)
            .stroke(Theme.accent,
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
    }

    private func handle(at point: CGPoint, kind: Handle) -> some View {
        let active = dragging == kind
        return Circle()
            .fill(Theme.accent)
            .overlay(Circle().strokeBorder(Theme.card, lineWidth: 2))
            .frame(width: active ? 16 : 13, height: active ? 16 : 13)
            .shadow(color: Theme.accent.opacity(active ? 0.6 : 0.3), radius: active ? 7 : 3)
            .position(point)
            .animation(.spring(duration: 0.25), value: active)
    }

    /// Where the machine is right now: dashed rule, dot on the ramp, reading.
    private func liveMarker(temp: Double, w: CGFloat, h: CGFloat) -> some View {
        let px = x(temp, in: w)
        let fraction = FanSettings(mode: .sensor, minTemp: minTemp, maxTemp: maxTemp)
            .rampFraction(at: temp)
        let py = h * CGFloat(1 - fraction)
        return ZStack {
            Path { path in
                path.move(to: CGPoint(x: px, y: 0))
                path.addLine(to: CGPoint(x: px, y: h))
            }
            .stroke(Color.primary.opacity(0.18),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            Circle()
                .fill(.white)
                .frame(width: 9, height: 9)
                .shadow(radius: 2)
                .position(x: px, y: py)
            Text(Format.temperature(temp))
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(Theme.card))
                .position(x: min(w - 22, max(22, px)), y: max(10, py - 16))
        }
        .animation(.easeInOut(duration: 0.4), value: temp)
    }

    private func axisLabels(w: CGFloat, h: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Text(Format.temperature(minTemp))
                .position(x: min(w - 20, max(20, x(minTemp, in: w))), y: h + 10)
            Text(Format.temperature(maxTemp))
                .position(x: min(w - 20, max(20, x(maxTemp, in: w))), y: h + 10)
            Text("\(Int(maxRPM)) RPM").position(x: w - 32, y: 8)
            Text("\(Int(minRPM)) RPM").position(x: w - 32, y: h - 8)
        }
        .font(.system(size: 10))
        .monospacedDigit()
        .foregroundStyle(Theme.textMuted)
    }
}
