import Foundation
import SwiftUI
import Combine

/// Central observable model. Owns the monitoring services and republishes their
/// readings on a timer so every SwiftUI surface (window + menu bar) stays in
/// sync from one polling loop.
@MainActor
final class AppState: ObservableObject {

    // Live metrics
    @Published var cpuUsage: Double = 0                 // 0...1
    @Published var memory = MemoryMonitor.Snapshot(usedBytes: 0, totalBytes: 0)
    @Published var disk = DiskMonitor.Snapshot(usedBytes: 0, totalBytes: 0)
    @Published var battery: BatteryService.Snapshot?
    /// Curated sensors for the dashboard.
    @Published var temperatures: [SensorService.Temperature] = []
    /// Every sensor the SMC exposes — the full table and the fan sensor picker.
    @Published var allTemperatures: [SensorService.Temperature] = []
    @Published var fans: [SensorService.Fan] = []
    @Published var cpuTemperature: Double?
    /// Sensor names for pickers — set once, never on the polling tick.
    @Published private(set) var sensorCatalog: [(key: String, label: String)] = []

    // User settings (persisted)
    @AppStorage("refreshInterval") var refreshInterval: Double = 2.0
    @AppStorage("temperatureAlertThreshold") var temperatureAlert: Double = 90
    @AppStorage("showMenuBarTemperature") var showMenuBarTemperature: Bool = true
    @AppStorage("showMenuBarFanSpeed") var showMenuBarFanSpeed: Bool = true
    @AppStorage("useFahrenheit") var useFahrenheit: Bool = false
    /// SMC keys shown in the menu bar, comma separated. Empty = CPU temperature.
    @AppStorage("menuBarSensorKeys") var menuBarSensorKeys: String = ""

    private let cpuMonitor = CPUMonitor()
    private let memoryMonitor = MemoryMonitor()
    private let sensors = SensorService()
    private var timer: AnyCancellable?
    private var lastAlertFired: Date?
    private var lastDiskSample: Date?
    private var isSamplingDisk = false

    let fanController = FanController()
    lazy var fanControl = FanControlEngine(controller: fanController)
    let fanPresets = FanPresetStore()

    /// Screens that display the whole sensor table hold this open while they
    /// are visible. Sweeping every key costs tens of milliseconds per tick, so
    /// everywhere else only the dashboard sensors — plus whatever the fan rules
    /// and menu bar reference — are read.
    @Published private var fullSensorClients = 0

    var wantsAllSensors: Bool { fullSensorClients > 0 }
    func retainFullSensors() { fullSensorClients += 1 }
    func releaseFullSensors() { fullSensorClients = max(0, fullSensorClients - 1) }

    /// Non-primary sensors something depends on, so they stay readable even
    /// during the cheap sweep.
    private var referencedSensorKeys: Set<String> {
        var keys = Set(menuBarSensorKeys.split(separator: ",").map(String.init))
        for settings in fanControl.settings.values where !settings.sensorKey.isEmpty {
            keys.insert(settings.sensorKey)
        }
        return keys
    }

    /// Sensors chosen for the menu bar, resolved against the live readings.
    var menuBarSensors: [SensorService.Temperature] {
        let keys = menuBarSensorKeys.split(separator: ",").map(String.init)
        guard !keys.isEmpty else { return [] }
        return keys.compactMap { key in allTemperatures.first { $0.id == key } }
    }

    /// Exponential moving average factor for jittery metrics (higher = snappier).
    private let smoothing = 0.35
    private var smoothedCPU: Double?
    private var smoothedCPUTemp: Double?

    /// Assign only when the value really changed, so @Published stays quiet and
    /// no view is rebuilt for an identical reading.
    private func assign<T: Equatable>(_ property: inout T, to value: T) {
        if property != value { property = value }
    }

    /// Half a degree — finer than the one-degree figures on screen.
    private static func quantised(_ t: SensorService.Temperature) -> SensorService.Temperature {
        SensorService.Temperature(id: t.id, label: t.label,
                                  celsius: (t.celsius * 2).rounded() / 2,
                                  isPrimary: t.isPrimary)
    }

    /// Ten RPM — below what the readouts or the meters can show.
    private static func quantised(_ f: SensorService.Fan) -> SensorService.Fan {
        SensorService.Fan(id: f.id,
                          rpm: (f.rpm / 10).rounded() * 10,
                          minRPM: f.minRPM, maxRPM: f.maxRPM,
                          targetRPM: (f.targetRPM / 10).rounded() * 10,
                          isManual: f.isManual)
    }

    private func smooth(_ previous: inout Double?, with raw: Double) -> Double {
        let next = previous.map { $0 + smoothing * (raw - $0) } ?? raw
        previous = next
        return next
    }

    func start() {
        sensors.start()
        sensorCatalog = sensors.catalog()
        // Clear any manual fan state an earlier run left behind before we do
        // anything else. A fan left in manual mode keeps whatever target it was
        // given — including a bad one — and will not respond to heat. The
        // engine re-applies the user's own rules on the first tick.
        if HelperInstaller.isUsable { try? fanController.resetAllDirect() }
        // Prime the CPU sampler so the first visible value is meaningful.
        _ = cpuMonitor.sample()
        refresh()
        scheduleTimer()
    }

    func scheduleTimer() {
        timer?.cancel()
        timer = Timer.publish(every: max(1, refreshInterval), on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        // Publish at the precision the UI actually shows. Readings wobble in
        // the last decimal every tick; assigning those straight through
        // republished the whole model twice a second and made SwiftUI rebuild
        // and re-lay out every screen for changes nobody can see.
        let rawCPU = smooth(&smoothedCPU, with: cpuMonitor.sample())
        assign(&cpuUsage, to: (rawCPU * 200).rounded() / 200)     // 0.5% steps
        assign(&memory, to: memoryMonitor.sample())
        refreshDiskIfStale()
        assign(&battery, to: BatteryService.sample())

        let freshTemps = sensors.temperatures(primaryOnly: !wantsAllSensors,
                                              including: referencedSensorKeys)
            .map { Self.quantised($0) }
        if freshTemps != allTemperatures {
            allTemperatures = freshTemps
            temperatures = freshTemps.filter(\.isPrimary)
        }
        assign(&fans, to: sensors.fans().map { Self.quantised($0) })

        let rawCPUTemp = temperatures.filter { $0.label.hasPrefix("CPU") }.map(\.celsius).max()
            ?? temperatures.map(\.celsius).max()
        assign(&cpuTemperature,
               to: rawCPUTemp.map { (smooth(&smoothedCPUTemp, with: $0) * 2).rounded() / 2 })
        evaluateTemperatureAlert()
        fanControl.evaluate(temperatures: allTemperatures,
                            cpuTemperature: cpuTemperature,
                            fans: fans)
    }

    /// Free space is the most expensive reading we take — asking for the
    /// "important usage" capacity makes the system work out purgeable space,
    /// which took ~90% of every polling tick and stuttered scrolling. It also
    /// barely changes, so sample it off the main thread twice a minute.
    private func refreshDiskIfStale() {
        guard !isSamplingDisk else { return }
        if let last = lastDiskSample, Date().timeIntervalSince(last) < 30 { return }
        isSamplingDisk = true
        Task.detached(priority: .utility) {
            let snapshot = DiskMonitor.sample()
            await MainActor.run {
                self.disk = snapshot
                self.lastDiskSample = Date()
                self.isSamplingDisk = false
            }
        }
    }

    /// Fire a notification at most once every 5 minutes while over threshold.
    private func evaluateTemperatureAlert() {
        guard let temp = cpuTemperature, temp >= temperatureAlert else { return }
        if let last = lastAlertFired, Date().timeIntervalSince(last) < 300 { return }
        lastAlertFired = Date()
        NotificationService.shared.postTemperatureAlert(celsius: temp)
    }
}

/// Formatting helpers shared across views.
enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
    static func bytes(_ value: UInt64) -> String { bytes(Int64(value)) }

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// Display unit follows the user's preference (shared via UserDefaults with
    /// AppState's @AppStorage flag, so both stay in sync).
    static var useFahrenheit: Bool { UserDefaults.standard.bool(forKey: "useFahrenheit") }

    static func temperature(_ celsius: Double?) -> String {
        guard let c = celsius else { return "—" }
        return useFahrenheit ? String(format: "%.0f°F", c * 9 / 5 + 32)
                             : String(format: "%.0f°C", c)
    }
}
