import Foundation

/// How one fan is driven. Mirrors the three modes users expect from a fan
/// utility: leave it to the firmware, pin it to a speed, or ramp it between
/// two temperatures of a chosen sensor.
enum FanMode: String, Codable, CaseIterable, Identifiable {
    case auto
    case constant
    case sensor

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .constant: return "Constant"
        case .sensor: return "Sensor"
        }
    }

    var systemImage: String {
        switch self {
        case .auto: return "wand.and.stars"
        case .constant: return "speedometer"
        case .sensor: return "thermometer.variable"
        }
    }
}

/// Configuration for a single fan.
///
/// In `.sensor` mode the fan sits at its minimum up to `minTemp`, ramps
/// linearly to full speed at `maxTemp`, and stays there above it — the same
/// mental model as Macs Fan Control, expressed in real degrees rather than an
/// abstract 0…1 curve.
struct FanSettings: Codable, Equatable {
    var mode: FanMode = .auto
    /// Target speed for `.constant`. Zero means "not chosen yet"; the UI seeds
    /// it from the fan's current speed.
    var constantRPM: Double = 0
    /// SMC key of the driving sensor for `.sensor`. Empty = hottest CPU sensor.
    var sensorKey: String = ""
    var minTemp: Double = 55
    var maxTemp: Double = 85

    /// Fan speed fraction (0 = fan minimum, 1 = fan maximum) for a temperature.
    func rampFraction(at celsius: Double) -> Double {
        let low = min(minTemp, maxTemp - 1)
        let high = max(maxTemp, low + 1)
        if celsius <= low { return 0 }
        if celsius >= high { return 1 }
        return (celsius - low) / (high - low)
    }

    /// Human description used in summaries and the menu bar.
    func summary(unit: (Double) -> String) -> String {
        switch mode {
        case .auto: return "Firmware controlled"
        case .constant: return "\(Int(constantRPM)) RPM fixed"
        case .sensor: return "\(unit(minTemp)) → \(unit(maxTemp))"
        }
    }
}

/// A named set of per-fan settings the user can switch between.
struct FanPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var systemImage: String = "square.stack"
    /// Keyed by fan index.
    var settings: [Int: FanSettings]

    // MARK: - Built-in starting points

    /// Presets shipped with the app, sized against the fans actually present.
    static func builtIns(for fans: [SensorService.Fan]) -> [FanPreset] {
        [
            FanPreset(name: "Quiet",
                      systemImage: "moon",
                      settings: uniform(FanSettings(mode: .sensor, minTemp: 68, maxTemp: 95),
                                        across: fans)),
            FanPreset(name: "Balanced",
                      systemImage: "dial.medium",
                      settings: uniform(FanSettings(mode: .sensor, minTemp: 55, maxTemp: 85),
                                        across: fans)),
            FanPreset(name: "Cool",
                      systemImage: "snowflake",
                      settings: uniform(FanSettings(mode: .sensor, minTemp: 42, maxTemp: 70),
                                        across: fans)),
            FanPreset(name: "Max",
                      systemImage: "bolt.fill",
                      settings: fans.reduce(into: [:]) { result, fan in
                          result[fan.id] = FanSettings(mode: .constant, constantRPM: fan.maxRPM)
                      }),
        ]
    }

    private static func uniform(_ settings: FanSettings,
                                across fans: [SensorService.Fan]) -> [Int: FanSettings] {
        fans.reduce(into: [:]) { result, fan in result[fan.id] = settings }
    }
}
