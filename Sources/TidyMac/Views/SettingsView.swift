import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue
    @AppStorage(Haptics.soundEffectsKey) private var playSounds = true

    private var soundEffects: Binding<Bool> { $playSounds }

    private static var bundleVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            alerts.tabItem { Label("Alerts", systemImage: "bell") }
            ScheduleSettingsView()
                .tabItem { Label("Schedule", systemImage: "calendar") }
            HelperSettingsView()
                .tabItem { Label("Fan Helper", systemImage: "shield") }
            about.tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 500, height: 400)
    }

    private var general: some View {
        Form {
            Picker("Appearance", selection: $appearanceRaw) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.label).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: appearanceRaw) { _, raw in
                (AppearanceMode(rawValue: raw) ?? .system).apply()
            }

            Slider(value: $state.refreshInterval, in: 1...10, step: 1) {
                Text("Refresh interval")
            } minimumValueLabel: { Text("1s") } maximumValueLabel: { Text("10s") }
                .onChange(of: state.refreshInterval) { _, _ in state.scheduleTimer() }
            Text("Currently every \(Int(state.refreshInterval)) second(s)")
                .font(.caption).foregroundStyle(.secondary)

            Picker("Temperature unit", selection: $state.useFahrenheit) {
                Text("Celsius (°C)").tag(false)
                Text("Fahrenheit (°F)").tag(true)
            }

            Toggle("Play a sound when a scan or cleanup finishes", isOn: soundEffects)

            Toggle("Show CPU temperature in menu bar", isOn: $state.showMenuBarTemperature)
            Toggle("Show fan speed in menu bar", isOn: $state.showMenuBarFanSpeed)
            Text("Pin any other sensor to the menu bar from the Sensors screen.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
    }

    private var alerts: some View {
        Form {
            Slider(value: $state.temperatureAlert, in: 60...105, step: 5) {
                Text("Temperature alert")
            } minimumValueLabel: { Text("60°") } maximumValueLabel: { Text("105°") }
            Text("Notify when CPU reaches \(Int(state.temperatureAlert))°C")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
    }

    private var about: some View {
        VStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 40)).foregroundStyle(.tint)
            Text("TidyMac").font(.title2.weight(.bold))
            Text("System monitor, fan control & cleaner")
                .font(.caption).foregroundStyle(.secondary)
            // Read from the bundle, never a literal: the release workflow sets
            // the version from the git tag, so a hard-coded string here means
            // every published build claims whatever number was typed last.
            Text("Version \(Self.bundleVersion)")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
