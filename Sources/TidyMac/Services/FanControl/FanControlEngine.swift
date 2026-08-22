import Foundation
import SwiftUI

/// Applies per-fan rules to the hardware.
///
/// Every polling tick each non-auto fan is re-evaluated: `.constant` holds its
/// RPM, `.sensor` maps its sensor's temperature onto the fan's min…max range.
/// Writes go through the *installed* privileged helper so the engine can run
/// unattended; without it, changes still work but cost one password prompt each
/// and no background ticking happens.
///
/// Safety rules:
///  - hysteresis: skip rewrites smaller than `rpmDeadband` RPM
///  - fail-safe: a sensor that stops reporting returns *its* fan to auto
///  - teardown: `resetAll()` hands every fan back to the firmware
@MainActor
final class FanControlEngine: ObservableObject {

    @Published private(set) var settings: [Int: FanSettings] = [:]
    @Published var lastAction: String?
    @Published var lastError: String?
    /// Name of the preset currently applied, if the settings still match it.
    @Published var activePresetName: String?

    private let controller: FanController
    private var lastAppliedRPM: [Int: Double] = [:]
    private let rpmDeadband: Double = 100
    private static let defaultsKey = "fanSettingsByIndex"

    init(controller: FanController) {
        self.controller = controller
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([Int: FanSettings].self, from: data) {
            settings = saved
        }
    }

    /// True when at least one fan is under our control rather than the firmware's.
    var hasOverrides: Bool { settings.values.contains { $0.mode != .auto } }

    /// Prompt-free control needs the one-time helper install — and the copy on
    /// disk must match this build. An outdated helper falls back to the
    /// prompting path, which runs the (correct) binary inside the app bundle.
    var canRunUnattended: Bool { HelperInstaller.isUsable }

    func settings(for fanID: Int) -> FanSettings { settings[fanID] ?? FanSettings() }

    /// Record a value mid-drag without writing to the hardware. The UI calls
    /// `update` once the drag ends, so a slider sweep is one SMC write.
    func stageLocal(_ new: FanSettings, for fanID: Int) {
        settings[fanID] = new
    }

    // MARK: - Mutation

    /// Store a fan's new settings and push them to the hardware immediately.
    func update(_ new: FanSettings,
                for fanID: Int,
                fans: [SensorService.Fan],
                temperatures: [SensorService.Temperature],
                cpuTemperature: Double?) {
        settings[fanID] = new
        activePresetName = nil
        persist()
        lastAppliedRPM[fanID] = nil

        guard let fan = fans.first(where: { $0.id == fanID }) else { return }
        if new.mode == .auto {
            handOverToFirmware(fanID: fanID)
        } else if let rpm = targetRPM(for: fan, settings: new,
                                      temperatures: temperatures, cpuTemperature: cpuTemperature) {
            apply(rpm: rpm, to: fan)
        }
    }

    /// Swap in a whole preset at once.
    func apply(preset: FanPreset,
               fans: [SensorService.Fan],
               temperatures: [SensorService.Temperature],
               cpuTemperature: Double?) {
        settings = preset.settings
        persist()
        lastAppliedRPM.removeAll()
        for fan in fans {
            let fanSettings = settings(for: fan.id)
            if fanSettings.mode == .auto {
                handOverToFirmware(fanID: fan.id)
            } else if let rpm = targetRPM(for: fan, settings: fanSettings,
                                          temperatures: temperatures, cpuTemperature: cpuTemperature) {
                apply(rpm: rpm, to: fan)
            }
        }
        activePresetName = preset.name
        lastAction = "Applied preset “\(preset.name)”"
    }

    /// Hand every fan back to the firmware and forget the overrides.
    func resetAll() {
        settings = [:]
        activePresetName = nil
        persist()
        lastAppliedRPM.removeAll()
        do {
            if canRunUnattended { try controller.resetAllDirect() }
            else { try controller.resetAll() }
            lastAction = "All fans returned to automatic"
            lastError = nil
        } catch {
            reportFailure(error)
        }
    }

    // MARK: - Engine tick

    /// Called from the app's polling loop with the latest readings.
    func evaluate(temperatures: [SensorService.Temperature],
                  cpuTemperature: Double?,
                  fans: [SensorService.Fan]) {
        // Background re-assertion only makes sense with the prompt-free helper.
        guard canRunUnattended else {
            warnIfFansAreStuck(fans)
            return
        }
        guard hasOverrides else { return }

        for fan in fans {
            let fanSettings = settings(for: fan.id)
            guard fanSettings.mode != .auto else { continue }

            guard let rpm = targetRPM(for: fan, settings: fanSettings,
                                      temperatures: temperatures, cpuTemperature: cpuTemperature) else {
                // Fail-safe: the driving sensor vanished — give this fan back.
                settings[fan.id] = FanSettings()
                persist()
                handOverToFirmware(fanID: fan.id)
                lastError = "Fan \(fan.id + 1): lost its sensor reading, returned to auto"
                continue
            }
            if let last = lastAppliedRPM[fan.id], abs(last - rpm) < rpmDeadband { continue }
            apply(rpm: rpm, to: fan)
        }
    }

    /// Without a usable helper we cannot write to the SMC unprompted — so if the
    /// hardware still reports a fan under manual control, say so loudly. A fan
    /// stuck in manual keeps its old target and will not speed up as the Mac
    /// heats, which is the worst failure this app can have.
    private func warnIfFansAreStuck(_ fans: [SensorService.Fan]) {
        let stuck = fans.filter(\.isManual)
        guard !stuck.isEmpty else { return }
        let names = stuck.map { "Fan \($0.id + 1)" }.joined(separator: ", ")
        lastError = "\(names) still under manual control from an earlier run — "
            + "install or update the helper, or press Reset all to Auto, so the "
            + "system can cool normally."
    }

    // MARK: - Rule evaluation

    /// Resolve a fan's target RPM, or nil when its sensor has no reading.
    func targetRPM(for fan: SensorService.Fan,
                   settings: FanSettings,
                   temperatures: [SensorService.Temperature],
                   cpuTemperature: Double?) -> Double? {
        switch settings.mode {
        case .auto:
            return nil
        case .constant:
            return clamp(settings.constantRPM, to: fan)
        case .sensor:
            guard let temp = temperature(forKey: settings.sensorKey,
                                         temperatures: temperatures,
                                         cpuTemperature: cpuTemperature) else { return nil }
            let fraction = settings.rampFraction(at: temp)
            return clamp(fan.minRPM + fraction * max(0, fan.maxRPM - fan.minRPM), to: fan)
        }
    }

    /// Reading for a sensor key; an empty key means "hottest CPU sensor".
    func temperature(forKey key: String,
                     temperatures: [SensorService.Temperature],
                     cpuTemperature: Double?) -> Double? {
        guard !key.isEmpty else { return cpuTemperature }
        return temperatures.first { $0.id == key }?.celsius
    }

    private func clamp(_ rpm: Double, to fan: SensorService.Fan) -> Double {
        max(fan.minRPM, min(fan.maxRPM, rpm))
    }

    // MARK: - Hardware writes

    private func apply(rpm: Double, to fan: SensorService.Fan) {
        do {
            if canRunUnattended { try controller.setManualDirect(fanIndex: fan.id, rpm: rpm) }
            else { try controller.setManual(fanIndex: fan.id, rpm: rpm) }
            lastAppliedRPM[fan.id] = rpm
            lastAction = "Fan \(fan.id + 1) → \(Int(rpm)) RPM"
            lastError = nil
        } catch {
            reportFailure(error)
        }
    }

    private func handOverToFirmware(fanID: Int) {
        lastAppliedRPM[fanID] = nil
        do {
            if canRunUnattended { try controller.setAutomaticDirect(fanIndex: fanID) }
            else { try controller.setAutomatic(fanIndex: fanID) }
            lastError = nil
        } catch {
            reportFailure(error)
        }
    }

    private func reportFailure(_ error: Error) {
        // Cancelling the authentication prompt is a normal action, not a fault.
        guard !"\(error)".contains("-128") else { return }
        lastError = "Couldn't change the fan speed — try reinstalling the helper"
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}
