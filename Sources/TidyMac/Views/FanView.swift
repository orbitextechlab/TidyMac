import SwiftUI

/// Fan control: presets on top, then one card per fan where each fan picks its
/// own mode — leave it to the firmware, pin a speed, or ramp against a sensor
/// of the user's choosing. Changes apply as soon as you let go; there is no
/// separate Apply step.
struct FanView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var state: AppState

    @State private var helperUsable = HelperInstaller.isUsable
    @State private var rivalController: String?
    @State private var helperOutdated = HelperInstaller.isOutdated
    @State private var isInstallingHelper = false
    @State private var showSavePreset = false
    @State private var newPresetName = ""

    private var engine: FanControlEngine { state.fanControl }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if engine.firmwareRejectsWrites {
                    firmwareBanner
                } else {
                    if let rival = rivalController { rivalBanner(rival) }
                    if !helperUsable { helperBanner }
                }
                if state.fans.isEmpty {
                    ContentUnavailableView("No fans detected",
                        systemImage: "fan.slash",
                        description: Text("This Mac has no controllable fans, or the SMC is unavailable."))
                        .frame(maxWidth: .infinity, minHeight: 260)
                } else {
                    // With the firmware verdict in, live-looking controls
                    // would be theater — dim and disable them; the banner
                    // explains why and offers a re-test.
                    Group {
                        presetBar
                        ForEach(Array(state.fans.enumerated()), id: \.element.id) { index, fan in
                            fanCard(fan).staggeredEntrance(index + 1)
                        }
                        statusLine
                    }
                    .disabled(engine.firmwareRejectsWrites)
                    .opacity(engine.firmwareRejectsWrites ? 0.45 : 1)
                }
            }
            .padding(28)
            .frame(maxWidth: 1080)
            .frame(maxWidth: .infinity)
        }
        // The sensor picker lists every sensor, so keep the full sweep alive
        // while this screen is visible. Re-check the helper too: it may have
        // been installed or removed from Settings since we were last shown.
        .onAppear {
            state.retainFullSensors()
            helperUsable = HelperInstaller.isUsable
            helperOutdated = HelperInstaller.isOutdated
            rivalController = FanRivalDetector.runningRival()
        }
        .onDisappear { state.releaseFullSensors() }
        .alert("Save current setup as a preset", isPresented: $showSavePreset) {
            TextField("Preset name", text: $newPresetName)
            Button("Save") {
                state.fanPresets.save(name: newPresetName, settings: engine.settings)
                newPresetName = ""
            }
            Button("Cancel", role: .cancel) { newPresetName = "" }
        } message: {
            Text("Stores every fan's current mode and thresholds under one name.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Fan Control").font(.pageTitle)
                Text(engine.hasOverrides
                     ? "\(overrideCount) of \(state.fans.count) fans under your control"
                     : "All fans are firmware controlled")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            Button("Reset all to Auto") { engine.resetAll() }
                .disabled(state.fans.isEmpty || !engine.hasOverrides)
        }
    }

    private var overrideCount: Int {
        state.fans.filter { engine.settings(for: $0.id).mode != .auto }.count
    }

    /// This OS accepted our fan writes and silently kept its own values, with
    /// no rival software running — fan control is simply not permitted here.
    /// Own the limitation instead of showing controls that do nothing.
    private var firmwareBanner: some View {
        GlassCard(padding: 13) {
            HStack(spacing: 11) {
                Image(systemName: "fan.slash")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.warning)
                VStack(alignment: .leading, spacing: 1) {
                    Text("macOS is not accepting fan-speed commands on this Mac")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text("The firmware acknowledged TidyMac's commands but kept control of the fans — this macOS version appears to block fan control entirely. No app can override it, including other fan tools. Monitoring and sensors still work; every fan has been returned to automatic.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Test Again") { engine.retryFirmwareControl() }
                    .help("Probe the firmware again — useful after removing another fan tool or updating macOS.")
            }
        }
    }

    /// Another fan tool's daemon is running: every write TidyMac makes gets
    /// overwritten within milliseconds, so its own controls are theater until
    /// the rival goes away. Say so plainly instead of failing mysteriously.
    private func rivalBanner(_ name: String) -> some View {
        GlassCard(padding: 13) {
            HStack(spacing: 11) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.warning)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(name) is controlling this Mac's fans")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text("Its background helper keeps overriding TidyMac's fan commands — even when the app is closed. Quit or uninstall \(name) (including its helper) to control fans from here.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
        }
    }

    private var helperBanner: some View {
        GlassCard(padding: 13) {
            HStack(spacing: 11) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(helperOutdated ? "Helper needs updating" : "One-time setup")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(helperOutdated
                         ? "The installed helper is from an older build — background fan control is paused until you update it."
                         : "Install the helper so fan changes apply instantly, without a password each time.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Button {
                    installHelper()
                } label: {
                    if isInstallingHelper {
                        SpinnerRing(size: 13, lineWidth: 2)
                    } else {
                        Text(helperOutdated ? "Update…" : "Install…")
                    }
                }
                .disabled(isInstallingHelper)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1)
        )
    }

    // MARK: - Presets

    private var presetBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Presets")
            HStack(spacing: 8) {
                ForEach(state.fanPresets.all(for: state.fans)) { preset in
                    presetChip(preset)
                }
                Button {
                    showSavePreset = true
                } label: {
                    Label("Save current", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 11).padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .neuRaised(99)
                .disabled(!engine.hasOverrides)
                Spacer()
            }
        }
    }

    private func presetChip(_ preset: FanPreset) -> some View {
        let active = engine.activePresetName == preset.name
        return Button {
            withAnimation(reduceMotion ? nil : Theme.Motion.snappy) {
                engine.apply(preset: preset,
                             fans: state.fans,
                             temperatures: state.allTemperatures,
                             cpuTemperature: state.cpuTemperature)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: preset.systemImage).font(.system(size: 11))
                Text(preset.name).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(active ? .white : .primary)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(
                Capsule().fill(active ? Theme.accent : Theme.chipFill)
                    .overlay(Capsule().strokeBorder(active ? .clear : Theme.border, lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            if state.fanPresets.isUserPreset(preset) {
                Button("Delete Preset", role: .destructive) { state.fanPresets.delete(preset) }
            }
        }
    }

    // MARK: - Per-fan card

    private func fanCard(_ fan: SensorService.Fan) -> some View {
        let settings = engine.settings(for: fan.id)
        return GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    FanGlyph(rpm: fan.rpm)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Fan \(fan.id + 1)")
                            .font(.system(size: 13.5, weight: .semibold))
                        Text("\(Int(fan.minRPM))–\(Int(fan.maxRPM)) RPM range")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textMuted)
                    }
                    Spacer()
                    NeuValueChip(text: "\(Int(fan.rpm)) RPM",
                                 font: .system(size: 14, weight: .bold))
                    modePicker(fan: fan, settings: settings)
                }

                Meter(fraction: fan.loadFraction,
                      color: settings.mode == .auto ? Theme.neutralFill : Theme.accent)

                switch settings.mode {
                case .auto:
                    Text("The firmware decides this fan's speed.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textMuted)
                case .constant:
                    constantControls(fan: fan, settings: settings)
                case .sensor:
                    sensorControls(fan: fan, settings: settings)
                }
            }
        }
    }

    private func modePicker(fan: SensorService.Fan, settings: FanSettings) -> some View {
        Picker("", selection: Binding(
            get: { settings.mode },
            set: { newMode in
                var updated = settings
                updated.mode = newMode
                // Seed a sensible starting speed the first time.
                if newMode == .constant && updated.constantRPM <= 0 {
                    updated.constantRPM = max(fan.minRPM, fan.rpm)
                }
                commit(updated, for: fan)
            }
        )) {
            ForEach(FanMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 220)
    }

    // MARK: - Constant mode

    private func constantControls(fan: SensorService.Fan, settings: FanSettings) -> some View {
        HStack(spacing: 12) {
            Text("Speed").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            Slider(value: Binding(
                get: { settings.constantRPM },
                set: { newValue in
                    // Track the drag locally; hardware is written on release.
                    var updated = settings
                    updated.constantRPM = newValue
                    engine.stageLocal(updated, for: fan.id)
                }
            ), in: fan.minRPM...max(fan.minRPM + 1, fan.maxRPM), step: 25) { editing in
                if !editing { commit(engine.settings(for: fan.id), for: fan) }
            }
            NeuValueChip(text: "\(Int(settings.constantRPM)) RPM",
                         font: .system(size: 11.5, weight: .semibold))
                .frame(width: 92, alignment: .trailing)
        }
    }

    // MARK: - Sensor mode

    private func sensorControls(fan: SensorService.Fan, settings: FanSettings) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Follow").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                Picker("", selection: Binding(
                    get: { settings.sensorKey },
                    set: { key in
                        var updated = settings
                        updated.sensorKey = key
                        commit(updated, for: fan)
                    }
                )) {
                    Text("Hottest CPU sensor").tag("")
                    Divider()
                    // Names only, from the stable catalog. Putting live
                    // readings in here rebuilt a few hundred menu items on
                    // every poll; the current value is shown beside the picker.
                    ForEach(state.sensorCatalog, id: \.key) { sensor in
                        Text(sensor.label).tag(sensor.key)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 280)
                if let now = engine.temperature(forKey: settings.sensorKey,
                                                temperatures: state.allTemperatures,
                                                cpuTemperature: state.cpuTemperature) {
                    NeuValueChip(text: Format.temperature(now),
                                 font: .system(size: 11, weight: .semibold),
                                 color: Theme.temperature(now))
                }
                Spacer()
                if let target = engine.targetRPM(for: fan, settings: settings,
                                                 temperatures: state.allTemperatures,
                                                 cpuTemperature: state.cpuTemperature) {
                    // Without a usable helper the engine computes this target
                    // but never writes it — showing a confident orange number
                    // while nothing happens is a lie. Say "paused" instead.
                    if helperUsable {
                        Text("target \(Int(target)) RPM")
                            .font(.system(size: 11.5, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.accent)
                            .contentTransition(.numericText())
                    } else {
                        Label("target \(Int(target)) RPM — paused, update the helper",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11.5, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.warning)
                            .help("The installed helper is from an older build, so background fan control is paused. Update it from the banner above or Settings → Fan Helper.")
                    }
                }
            }

            FanRampChart(
                minTemp: Binding(
                    get: { settings.minTemp },
                    set: { value in
                        var updated = engine.settings(for: fan.id)
                        updated.minTemp = value
                        engine.stageLocal(updated, for: fan.id)
                    }),
                maxTemp: Binding(
                    get: { settings.maxTemp },
                    set: { value in
                        var updated = engine.settings(for: fan.id)
                        updated.maxTemp = value
                        engine.stageLocal(updated, for: fan.id)
                    }),
                currentTemp: engine.temperature(forKey: settings.sensorKey,
                                                temperatures: state.allTemperatures,
                                                cpuTemperature: state.cpuTemperature),
                minRPM: fan.minRPM,
                maxRPM: fan.maxRPM,
                onCommit: { commit(engine.settings(for: fan.id), for: fan) }
            )

            // The same two thresholds as the chart handles, typed exactly.
            HStack(spacing: 18) {
                thresholdField("Starts at", celsius: settings.minTemp,
                               limits: 30...(settings.maxTemp - 5), fan: fan) { $0.minTemp = $1 }
                thresholdField("Full speed at", celsius: settings.maxTemp,
                               limits: (settings.minTemp + 5)...105, fan: fan) { $0.maxTemp = $1 }
                Spacer()
                Text("\(Int(fan.minRPM)) → \(Int(fan.maxRPM)) RPM")
                    .font(.system(size: 11)).monospacedDigit()
                    .foregroundStyle(Theme.textMuted)
            }

            Text("Below \(Format.temperature(settings.minTemp)) this fan idles at \(Int(fan.minRPM)) RPM; at \(Format.temperature(settings.maxTemp)) and above it runs flat out at \(Int(fan.maxRPM)) RPM. Type a value or drag either point on the chart.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Numeric entry for one ramp threshold: type a figure or use the stepper.
    /// Values are stored in Celsius but shown in whichever unit is selected.
    private func thresholdField(_ label: String,
                                celsius: Double,
                                limits: ClosedRange<Double>,
                                fan: SensorService.Fan,
                                write: @escaping (inout FanSettings, Double) -> Void) -> some View {
        let shown = Binding<Double>(
            get: { toDisplayUnit(celsius) },
            set: { newValue in
                let inCelsius = fromDisplayUnit(newValue)
                var updated = engine.settings(for: fan.id)
                write(&updated, min(max(inCelsius, limits.lowerBound), limits.upperBound))
                engine.stageLocal(updated, for: fan.id)
            }
        )
        return HStack(spacing: 5) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            TextField("", value: shown, format: .number.precision(.fractionLength(0)))
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
                .frame(width: 46)
                .onSubmit { commit(engine.settings(for: fan.id), for: fan) }
            Text(Format.useFahrenheit ? "°F" : "°C")
                .font(.system(size: 11)).foregroundStyle(Theme.textMuted)
            Stepper("", value: Binding(
                get: { shown.wrappedValue },
                set: { newValue in
                    shown.wrappedValue = newValue
                    commit(engine.settings(for: fan.id), for: fan)
                }
            ), in: toDisplayUnit(limits.lowerBound)...toDisplayUnit(limits.upperBound), step: 1)
            .labelsHidden()
        }
    }

    private func toDisplayUnit(_ celsius: Double) -> Double {
        Format.useFahrenheit ? celsius * 9 / 5 + 32 : celsius
    }

    private func fromDisplayUnit(_ shown: Double) -> Double {
        Format.useFahrenheit ? (shown - 32) * 5 / 9 : shown
    }

    // MARK: - Status

    @ViewBuilder
    private var statusLine: some View {
        if let error = engine.lastError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.system(size: 12)).foregroundStyle(Theme.critical)
        } else if let action = engine.lastAction {
            Label(action, systemImage: "checkmark.circle")
                .font(.system(size: 12)).foregroundStyle(Theme.ok)
        }
    }

    // MARK: - Actions

    private func commit(_ settings: FanSettings, for fan: SensorService.Fan) {
        engine.update(settings, for: fan.id,
                      fans: state.fans,
                      temperatures: state.allTemperatures,
                      cpuTemperature: state.cpuTemperature)
    }

    private func installHelper() {
        isInstallingHelper = true
        Task.detached(priority: .userInitiated) {
            let ok = (try? HelperInstaller.install()) != nil
            await MainActor.run {
                isInstallingHelper = false
                helperUsable = HelperInstaller.isUsable
                helperOutdated = HelperInstaller.isOutdated
                if !ok && !helperUsable {
                    engine.lastError = "Helper installation was cancelled or failed"
                }
            }
        }
    }
}

/// Fan glyph that spins at a speed proportional to the real RPM — a small
/// touch of life that also communicates state at a glance.
/// Fan glyph. Static on purpose: a spinning icon looked lively but kept
/// SwiftUI re-rendering these views continuously, and several on screen at once
/// were a measurable share of the app's CPU. Colour still distinguishes a
/// turning fan from a stopped one.
struct FanGlyph: View {
    let rpm: Double

    var body: some View {
        Image(systemName: "fan.fill")
            .font(.system(size: 15))
            .foregroundStyle(rpm > 0 ? Theme.accent : .secondary)
            .frame(width: 18, height: 18)
    }
}
