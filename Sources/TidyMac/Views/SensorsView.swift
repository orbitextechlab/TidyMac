import SwiftUI

/// Every sensor the SMC reports, in two tables: fans and temperatures.
/// Sensors can be pinned to the menu bar straight from here.
struct SensorsView: View {
    @EnvironmentObject private var state: AppState

    @State private var searchText = ""
    @State private var showAllSensors = true

    private var visibleSensors: [SensorService.Temperature] {
        let base = showAllSensors ? state.allTemperatures : state.temperatures
        guard !searchText.isEmpty else { return base }
        return base.filter {
            $0.label.localizedCaseInsensitiveContains(searchText)
                || $0.id.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var pinnedKeys: Set<String> {
        Set(state.menuBarSensorKeys.split(separator: ",").map(String.init))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if !state.fans.isEmpty { fanTable }
                temperatureTable
            }
            .padding(28)
            .frame(maxWidth: 1080)
            .frame(maxWidth: .infinity)
        }
        // The full sensor sweep only runs while this table is on screen.
        .onAppear { state.retainFullSensors() }
        .onDisappear { state.releaseFullSensors() }
    }

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Sensors").font(.pageTitle)
                Text("\(state.allTemperatures.count) temperature sensors · \(state.fans.count) fans")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Picker("", selection: $state.useFahrenheit) {
                Text("°C").tag(false)
                Text("°F").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 90)
            Toggle("All sensors", isOn: $showAllSensors)
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    // MARK: - Fans

    private var fanTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Fans")
            GlassCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(state.fans.enumerated()), id: \.element.id) { index, fan in
                        if index > 0 { Divider().opacity(0.5) }
                        HStack(spacing: 12) {
                            FanGlyph(rpm: fan.rpm)
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Fan \(fan.id + 1)")
                                    .font(.system(size: 12.5, weight: .medium))
                                Text(state.fanControl.settings(for: fan.id)
                                        .summary(unit: { Format.temperature($0) }))
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(Theme.textMuted)
                            }
                            Spacer()
                            Text("min \(Int(fan.minRPM)) · max \(Int(fan.maxRPM))")
                                .font(.system(size: 10.5)).monospacedDigit()
                                .foregroundStyle(Theme.textMuted)
                            Meter(fraction: fan.loadFraction, color: Theme.accent)
                                .frame(width: 120)
                            NeuValueChip(text: "\(Int(fan.rpm)) RPM",
                                         font: .system(size: 11.5, weight: .semibold))
                                .frame(width: 92, alignment: .trailing)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                }
            }
        }
    }

    // MARK: - Temperatures

    private var temperatureTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(title: "Temperatures")
                Spacer()
                TextField("Filter", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }
            GlassCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(visibleSensors.enumerated()), id: \.element.id) { index, sensor in
                        if index > 0 { Divider().opacity(0.5) }
                        sensorRow(sensor)
                    }
                    if visibleSensors.isEmpty {
                        Text("No sensor matches “\(searchText)”")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textMuted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 26)
                    }
                }
            }
        }
    }

    private func sensorRow(_ sensor: SensorService.Temperature) -> some View {
        let pinned = pinnedKeys.contains(sensor.id)
        return HStack(spacing: 12) {
            Button {
                togglePinned(sensor.id)
            } label: {
                Image(systemName: pinned ? "pin.fill" : "pin")
                    .font(.system(size: 11))
                    .foregroundStyle(pinned ? Theme.accent : Theme.textMuted)
                    .frame(width: 18)
            }
            .buttonStyle(.plain)
            .help(pinned ? "Remove from the menu bar" : "Show this sensor in the menu bar")

            Text(sensor.label)
                .font(.system(size: 12.5))
                .lineLimit(1)
            Text(sensor.id)
                .font(.system(size: 10))
                .monospaced()
                .foregroundStyle(Theme.textMuted)
            Spacer()
            Meter(fraction: sensor.celsius / 110,
                  color: Theme.temperature(sensor.celsius) == .secondary
                      ? Theme.neutralFill : Theme.temperature(sensor.celsius))
                .frame(width: 140)
            NeuValueChip(text: Format.temperature(sensor.celsius),
                         font: .system(size: 11.5, weight: .semibold),
                         color: Theme.temperature(sensor.celsius) == .secondary
                             ? .primary : Theme.temperature(sensor.celsius))
                .frame(width: 74, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func togglePinned(_ key: String) {
        var keys = state.menuBarSensorKeys.split(separator: ",").map(String.init)
        if let index = keys.firstIndex(of: key) { keys.remove(at: index) }
        else { keys.append(key) }
        state.menuBarSensorKeys = keys.joined(separator: ",")
    }
}
