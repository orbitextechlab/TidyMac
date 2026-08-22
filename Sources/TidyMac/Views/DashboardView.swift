import SwiftUI

/// System overview: a health verdict first, compact stats second, detail
/// meters last. The app should answer "is my Mac OK?" before showing numbers.
struct DashboardView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("System Overview").font(.pageTitle)
                    .staggeredEntrance(0)
                healthHero
                    .staggeredEntrance(1)
                statRow
                    .staggeredEntrance(2)
                if !state.temperatures.isEmpty {
                    temperatureSection.staggeredEntrance(3)
                }
                if !state.fans.isEmpty {
                    fanSection.staggeredEntrance(4)
                }
                if let battery = state.battery {
                    batterySection(battery).staggeredEntrance(5)
                }
            }
            .padding(24)
        }
    }

    // MARK: - Health verdict

    private var issues: [String] {
        var found: [String] = []
        if let temp = state.cpuTemperature, temp >= state.temperatureAlert {
            found.append(String(format: "CPU is running hot (%.0f°C)", temp))
        }
        if state.disk.usedFraction > 0.9 {
            found.append("Storage is almost full")
        }
        if let health = state.battery?.healthPercent, health < 80 {
            found.append("Battery health is at \(health)%")
        }
        return found
    }

    /// Gentle breathing pulse behind the health icon — alive, not alarming.
    @State private var heroPulse = false

    private var healthHero: some View {
        let ok = issues.isEmpty
        return HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 22))
                .foregroundStyle(ok ? Theme.ok : Theme.warning)
                // Scale and opacity only: both are layer properties Core
                // Animation can interpolate on its own. Animating the shadow
                // radius instead forced a CPU re-render every frame.
                .scaleEffect(heroPulse ? 1.07 : 1.0)
                .opacity(heroPulse ? 1.0 : 0.75)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                        heroPulse = true
                    }
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(ok ? "Your Mac is running smoothly" : issues[0])
                    .font(.system(size: 14, weight: .semibold))
                Text(ok ? "No issues detected"
                        : issues.count > 1 ? issues.dropFirst().joined(separator: " · ")
                        : "Details below")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.bottom, 4)
    }

    // MARK: - Stats

    private var statRow: some View {
        HStack(spacing: 12) {
            StatTile(label: "CPU",
                     value: Format.percent(state.cpuUsage),
                     detail: Format.temperature(state.cpuTemperature),
                     detailColor: state.cpuTemperature.map(Theme.temperature) ?? .secondary,
                     fraction: state.cpuUsage,
                     fillColor: Theme.usage(state.cpuUsage))

            StatTile(label: "Memory",
                     value: Format.percent(state.memory.usedFraction),
                     detail: "\(Format.bytes(state.memory.usedBytes)) used",
                     fraction: state.memory.usedFraction,
                     fillColor: Theme.usage(state.memory.usedFraction))

            StatTile(label: "Storage",
                     value: Format.percent(1 - state.disk.usedFraction) + " free",
                     detail: "\(Format.bytes(state.disk.totalBytes - state.disk.usedBytes)) available",
                     fraction: state.disk.usedFraction,
                     fillColor: Theme.usage(state.disk.usedFraction))

            if let battery = state.battery {
                StatTile(label: "Battery",
                         value: "\(battery.chargePercent)%",
                         detail: battery.isCharging ? "Charging"
                               : battery.isPlugged ? "Plugged in" : "On battery",
                         fraction: Double(battery.chargePercent) / 100,
                         fillColor: battery.chargePercent < 20 ? Theme.warning : Theme.neutralFill)
            }
        }
    }

    // MARK: - Detail sections

    private var temperatureSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Temperature")
            GlassCard {
                VStack(spacing: 10) {
                    ForEach(state.temperatures) { temp in
                        MeterRow(label: temp.label,
                                 value: Format.temperature(temp.celsius),
                                 fraction: temp.celsius / 100,
                                 color: Theme.temperature(temp.celsius) == .secondary
                                     ? Theme.neutralFill : Theme.temperature(temp.celsius))
                    }
                }
            }
        }
    }

    private var fanSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Fans")
            GlassCard {
                VStack(spacing: 10) {
                    ForEach(state.fans) { fan in
                        HStack(spacing: 14) {
                            HStack(spacing: 8) {
                                FanGlyph(rpm: fan.rpm)
                                Text("Fan \(fan.id + 1)")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            .frame(width: 110, alignment: .leading)
                            Meter(fraction: fan.loadFraction, color: Theme.accent)
                            NeuValueChip(text: "\(Int(fan.rpm)) RPM",
                                         font: .system(size: 11.5, weight: .semibold))
                                .frame(width: 74, alignment: .trailing)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
        }
    }

    private func batterySection(_ b: BatteryService.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Battery")
            GlassCard {
                VStack(spacing: 8) {
                    if let cycles = b.cycleCount { InfoRow(label: "Cycle count", value: "\(cycles)") }
                    if let health = b.healthPercent { InfoRow(label: "Health", value: "\(health)%") }
                    if let t = b.temperatureCelsius { InfoRow(label: "Temperature", value: Format.temperature(t)) }
                }
            }
        }
    }
}
