import Foundation

/// Reads temperature sensors and fan state from the SMC and exposes them as
/// simple value types the UI can bind to.
///
/// Temperature and fan keys differ between Intel and Apple Silicon Macs, so the
/// service probes a candidate list on first use and keeps only the keys that
/// actually respond. This keeps the app portable without hardcoding a machine
/// model table.
final class SensorService {

    struct Temperature: Identifiable, Equatable {
        let id: String        // SMC key
        let label: String
        let celsius: Double
        /// Curated sensors shown on the dashboard; the rest only appear in the
        /// full sensor table.
        var isPrimary: Bool = true
    }

    struct Fan: Identifiable, Equatable {
        let id: Int           // fan index
        let rpm: Double
        let minRPM: Double
        let maxRPM: Double
        let targetRPM: Double
        /// True when the SMC reports this fan is under manual (software)
        /// control. Read from the hardware rather than inferred from our own
        /// settings, so a state left behind by an earlier run is still visible.
        let isManual: Bool
        /// 0.0 (min) ... 1.0 (max) based on current RPM.
        var loadFraction: Double {
            guard maxRPM > minRPM else { return 0 }
            return max(0, min(1, (rpm - minRPM) / (maxRPM - minRPM)))
        }
    }

    private let smc = SMCKit()
    private var isOpen = false

    /// Candidate temperature keys with human labels. Missing keys are skipped.
    private let temperatureCandidates: [(key: String, label: String)] = [
        // Apple Silicon common keys
        ("Tp09", "CPU P-core"),
        ("Tp0T", "CPU E-core"),
        ("Tg05", "GPU"),
        ("Tm02", "Memory"),
        ("Ts1P", "Chassis"),
        // Intel common keys
        ("TC0P", "CPU proximity"),
        ("TC0E", "CPU core"),
        ("TG0P", "GPU proximity"),
        ("TM0P", "Memory proximity"),
        ("TA0P", "Ambient"),
        ("TB0T", "Battery"),
        ("TW0P", "Wireless"),
        ("Th0H", "Heatsink"),
    ]

    /// Prefix hints for keys discovered by sweeping the SMC table. The first
    /// two characters of a temperature key identify the subsystem.
    private let discoveredPrefixLabels: [(prefix: String, label: String)] = [
        ("TC", "CPU"), ("Tp", "CPU"), ("TG", "GPU"), ("Tg", "GPU"),
        ("TM", "Memory"), ("Tm", "Memory"), ("TA", "Ambient"), ("Ta", "Ambient"),
        ("TB", "Battery"), ("TW", "Wireless"), ("TH", "Drive"), ("Th", "Heatsink"),
        ("Ts", "Enclosure"), ("TP", "Power supply"), ("TN", "Northbridge"),
        ("TL", "Display"), ("TS", "Storage"), ("TE", "PCIe"), ("TI", "Airport"),
    ]

    private var resolvedTemperatureKeys: [(key: String, label: String, isPrimary: Bool)] = []

    // MARK: - Lifecycle

    func start() {
        guard !isOpen else { return }
        do {
            try smc.open()
            isOpen = true
            resolveKeys()
        } catch {
            NSLog("[SensorService] SMC open failed: \(error)")
        }
    }

    func stop() {
        smc.close()
        isOpen = false
    }

    /// Build the sensor list once: the curated keys with friendly names, plus
    /// every other live temperature key the SMC reports. Sweeping the whole key
    /// table is what surfaces drive, enclosure and power sensors without a
    /// per-model lookup table.
    private func resolveKeys() {
        var resolved: [(key: String, label: String, isPrimary: Bool)] = []
        var seen = Set<String>()

        for candidate in temperatureCandidates where isLiveTemperature(candidate.key) {
            resolved.append((candidate.key, candidate.label, true))
            seen.insert(candidate.key)
        }

        for key in smc.allKeys() where key.hasPrefix("T") && !seen.contains(key) {
            guard isLiveTemperature(key) else { continue }
            seen.insert(key)
            resolved.append((key, discoveredLabel(for: key), false))
        }

        resolvedTemperatureKeys = resolved
    }

    /// A key counts as a usable sensor when it decodes to a plausible reading.
    private func isLiveTemperature(_ key: String) -> Bool {
        guard let v = smc.readFloat(key) else { return false }
        // Disconnected sensors report 0 or garbage.
        return v > 1 && v < 130
    }

    /// Readable name for a swept key: subsystem hint plus the raw key, which
    /// stays meaningful even for sensors we have no name for.
    private func discoveredLabel(for key: String) -> String {
        let hint = discoveredPrefixLabels.first { key.hasPrefix($0.prefix) }?.label
        return hint.map { "\($0) (\(key))" } ?? key
    }

    // MARK: - Reads

    /// Last valid reading per key, so a transiently bad sample doesn't remove
    /// a row from the UI (which made the dashboard layout jump around).
    private var lastKnownCelsius: [String: Double] = [:]

    /// Sensor readings. `primaryOnly` restricts the sweep to the curated
    /// dashboard set — reading all ~200 keys costs tens of milliseconds, so
    /// callers ask for the full list only while a screen actually shows it, and
    /// name the extra keys they depend on (fan rules, menu bar) via `including`.
    func temperatures(primaryOnly: Bool = true,
                      including extraKeys: Set<String> = []) -> [Temperature] {
        guard isOpen else { return [] }
        return resolvedTemperatureKeys.compactMap { candidate in
            if primaryOnly && !candidate.isPrimary && !extraKeys.contains(candidate.key) {
                return nil
            }
            if let c = smc.readFloat(candidate.key), c > 1, c < 130 {
                lastKnownCelsius[candidate.key] = c
            }
            guard let value = lastKnownCelsius[candidate.key] else { return nil }
            return Temperature(id: candidate.key, label: candidate.label,
                               celsius: value, isPrimary: candidate.isPrimary)
        }
    }

    /// Stable list of every sensor this Mac exposes: key and name only, no
    /// readings. Pickers bind to this instead of the live array, which is
    /// rebuilt on every poll and would otherwise force a few hundred menu items
    /// to be recreated twice a second.
    func catalog() -> [(key: String, label: String)] {
        resolvedTemperatureKeys.map { ($0.key, $0.label) }
    }

    func fans() -> [Fan] {
        guard isOpen else { return [] }
        guard let count = smc.readFloat("FNum"), count > 0 else { return [] }
        var result: [Fan] = []
        for i in 0..<Int(count) {
            let actual = smc.readFloat("F\(i)Ac") ?? 0
            let min = smc.readFloat("F\(i)Mn") ?? 0
            let max = smc.readFloat("F\(i)Mx") ?? 0
            let target = smc.readFloat("F\(i)Tg") ?? actual
            let manual = (smc.readFloat("F\(i)Md") ?? 0) >= 1
            result.append(Fan(id: i, rpm: actual, minRPM: min, maxRPM: max,
                              targetRPM: target, isManual: manual))
        }
        return result
    }
}
