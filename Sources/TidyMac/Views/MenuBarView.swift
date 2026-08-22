import SwiftUI

/// The menu bar dropdown — a condensed version of the app's own dashboard,
/// built from the same pieces (Theme surface, GlassCard, StatTile, Meter,
/// SectionHeader) so it reads as the same product rather than a side panel.
/// Temperature and fan speed lead, because they are what people open it for.
struct MenuBarView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openWindow) private var openWindow

    /// Fastest fan: the one that says how hard the machine is working.
    private var leadFanRPM: Double? { state.fans.map(\.rpm).max() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            heroRow
            if !state.fans.isEmpty {
                section("Fans") { fanRows }
                section("Fan Preset") { presetRow }
            }
            section("System") { systemMeters }
            Divider().opacity(0.6)
            footer
        }
        .padding(14)
        .frame(width: 300)
        .background(Theme.surface)
    }

    /// Section wrapper matching the app's rhythm: quiet uppercase label, then
    /// the content grouped in a card.
    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.sectionHeader)
                .foregroundStyle(Theme.textMuted)
                .tracking(0.9)
            GlassCard(padding: 11) { content() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 12))
                .foregroundStyle(Theme.accent)
            Text("TidyMac").font(.system(size: 13, weight: .semibold))
            Spacer()
        }
    }

    // MARK: - Hero readouts

    private var heroRow: some View {
        HStack(spacing: 10) {
            StatTile(label: "CPU Temp",
                     value: Format.temperature(state.cpuTemperature),
                     valueColor: state.cpuTemperature.map(Theme.temperature) ?? .primary,
                     detail: state.cpuTemperature == nil ? "no sensor" : "current",
                     compact: true)
            StatTile(label: state.fans.count > 1 ? "Top Fan" : "Fan",
                     value: leadFanRPM.map { "\(Int($0))" } ?? "—",
                     valueColor: leadFanRPM == nil ? .primary : Theme.accent,
                     detail: leadFanRPM == nil ? "no fans" : "RPM",
                     compact: true)
        }
    }

    // MARK: - Fans

    private var fanRows: some View {
        VStack(spacing: 8) {
            ForEach(state.fans) { fan in
                HStack(spacing: 8) {
                    FanGlyph(rpm: fan.rpm)
                    Text("Fan \(fan.id + 1)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 40, alignment: .leading)
                    Meter(fraction: fan.loadFraction, color: Theme.accent, height: 5)
                    NeuValueChip(text: "\(Int(fan.rpm))",
                                 font: .system(size: 10.5, weight: .semibold))
                        .frame(width: 52, alignment: .trailing)
                }
            }
        }
    }

    // MARK: - System meters

    private var systemMeters: some View {
        VStack(spacing: 8) {
            meter("CPU", fraction: state.cpuUsage, value: Format.percent(state.cpuUsage))
            meter("Memory", fraction: state.memory.usedFraction,
                  value: Format.percent(state.memory.usedFraction))
            meter("Disk", fraction: state.disk.usedFraction,
                  value: Format.bytes(state.disk.totalBytes - state.disk.usedBytes))
        }
    }

    private func meter(_ title: String, fraction: Double, value: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 48, alignment: .leading)
            Meter(fraction: fraction, color: Theme.usage(fraction), height: 5)
            NeuValueChip(text: value, font: .system(size: 10.5, weight: .semibold))
                .frame(width: 68, alignment: .trailing)
        }
    }

    // MARK: - Presets

    private var presetRow: some View {
        HStack(spacing: 5) {
            ForEach(state.fanPresets.all(for: state.fans).prefix(4)) { preset in
                presetChip(preset)
            }
            Spacer(minLength: 0)
            Button {
                state.fanControl.resetAll()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 9))
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(
                        Capsule().fill(Theme.chipFill)
                            .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
                    )
            }
            .buttonStyle(.plain)
            .help("Return every fan to automatic")
        }
    }

    /// Same chip treatment as the Fan Control screen.
    private func presetChip(_ preset: FanPreset) -> some View {
        let active = state.fanControl.activePresetName == preset.name
        return Button {
            state.fanControl.apply(preset: preset,
                                   fans: state.fans,
                                   temperatures: state.allTemperatures,
                                   cpuTemperature: state.cpuTemperature)
        } label: {
            Text(preset.name)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(active ? .white : .primary)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(
                    Capsule().fill(active ? Theme.accent : Theme.chipFill)
                        .overlay(Capsule().strokeBorder(active ? .clear : Theme.border,
                                                        lineWidth: 1))
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 6) {
            Button {
                openWindow(id: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
            } label: {
                pillLabel("Open", icon: "macwindow")
            }
            .buttonStyle(.plain)

            // Settings belongs here as a plain labelled button: a bare gear in
            // the corner was too easy to miss.
            SettingsLink {
                pillLabel("Settings", icon: "gearshape")
            }
            .buttonStyle(.plain)
            // SettingsLink opens the window behind everything else when it is
            // triggered from a menu bar popover, so bring the app forward too.
            .simultaneousGesture(TapGesture().onEnded {
                NSApplication.shared.activate(ignoringOtherApps: true)
            })

            Spacer()
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Text("Quit")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 8).padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
        }
    }

    /// Shared pill styling for the footer actions.
    private func pillLabel(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(
                Capsule().fill(Theme.chipFill)
                    .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
            )
    }
}

/// The always-visible menu bar label: temperature and fan speed side by side,
/// each with its own glyph so the two numbers can't be confused.
struct MenuBarLabel: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 5) {
            if state.showMenuBarTemperature, let temp = state.cpuTemperature {
                reading("thermometer.medium", Format.temperature(temp))
            }
            ForEach(state.menuBarSensors) { sensor in
                reading("thermometer.variable", Format.temperature(sensor.celsius))
            }
            if state.showMenuBarFanSpeed, let rpm = state.fans.map(\.rpm).max() {
                reading("fan.fill", "\(Int(rpm))")
            }
            // Never leave the menu bar item blank if everything is switched off.
            if !state.showMenuBarTemperature && !state.showMenuBarFanSpeed
                && state.menuBarSensors.isEmpty {
                Image(systemName: "gauge.with.dots.needle.67percent")
            }
        }
    }

    private func reading(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).monospacedDigit()
        }
    }
}
