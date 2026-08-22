import Foundation
import Darwin
import IOKit.ps

/// CPU usage sampler based on host processor tick counters. Each call returns
/// the busy fraction (0...1) since the previous call, so it must be polled on a
/// timer to produce a live figure.
final class CPUMonitor {
    private var previousLoad: host_cpu_load_info?

    func sample() -> Double {
        guard let load = Self.hostCPULoad() else { return 0 }
        defer { previousLoad = load }
        guard let prev = previousLoad else { return 0 }

        let userDiff = Double(load.cpu_ticks.0 - prev.cpu_ticks.0)
        let systemDiff = Double(load.cpu_ticks.1 - prev.cpu_ticks.1)
        let idleDiff = Double(load.cpu_ticks.2 - prev.cpu_ticks.2)
        let niceDiff = Double(load.cpu_ticks.3 - prev.cpu_ticks.3)

        let used = userDiff + systemDiff + niceDiff
        let total = used + idleDiff
        return total > 0 ? used / total : 0
    }

    private static func hostCPULoad() -> host_cpu_load_info? {
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        var info = host_cpu_load_info()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        return result == KERN_SUCCESS ? info : nil
    }
}

/// Physical memory usage via the Mach VM statistics, reported the same way
/// Activity Monitor computes "Memory Used" (active + wired + compressed).
final class MemoryMonitor {
    struct Snapshot: Equatable {
        let usedBytes: UInt64
        let totalBytes: UInt64
        var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }
    }

    func sample() -> Snapshot {
        let total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return Snapshot(usedBytes: 0, totalBytes: total) }

        let pageSize = UInt64(vm_kernel_page_size)
        let active = UInt64(stats.active_count) * pageSize
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        return Snapshot(usedBytes: active + wired + compressed, totalBytes: total)
    }
}

/// Free/used capacity of the boot volume.
enum DiskMonitor {
    struct Snapshot: Equatable {
        let usedBytes: Int64
        let totalBytes: Int64
        var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }
    }

    static func sample() -> Snapshot {
        let url = URL(fileURLWithPath: "/")
        guard let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey
        ]),
        let total = values.volumeTotalCapacity else {
            return Snapshot(usedBytes: 0, totalBytes: 0)
        }
        let available = values.volumeAvailableCapacityForImportantUsage ?? 0
        return Snapshot(usedBytes: Int64(total) - available, totalBytes: Int64(total))
    }
}

/// Battery state via the IOKit power-source APIs. Returns nil on desktops.
enum BatteryService {
    struct Snapshot: Equatable {
        let chargePercent: Int
        let isCharging: Bool
        let isPlugged: Bool
        let cycleCount: Int?
        let healthPercent: Int?
        let temperatureCelsius: Double?
    }

    static func sample() -> Snapshot? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
              let first = sources.first,
              let desc = IOPSGetPowerSourceDescription(blob, first)?.takeUnretainedValue() as? [String: Any]
        else { return nil }

        let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
        let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
        let percent = max > 0 ? Int((Double(current) / Double(max)) * 100) : 0
        let state = desc[kIOPSPowerSourceStateKey] as? String
        let isPlugged = state == kIOPSACPowerValue
        let isCharging = desc[kIOPSIsChargingKey] as? Bool ?? false

        let (cycles, health, temp) = smartBatteryDetails()
        return Snapshot(chargePercent: percent,
                        isCharging: isCharging,
                        isPlugged: isPlugged,
                        cycleCount: cycles,
                        healthPercent: health,
                        temperatureCelsius: temp)
    }

    /// Extra fields (cycle count, design-capacity health, temperature) come from
    /// the AppleSmartBattery IOService, which the power-source API omits.
    private static func smartBatteryDetails() -> (Int?, Int?, Double?) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return (nil, nil, nil) }
        defer { IOObjectRelease(service) }

        func intProp(_ key: String) -> Int? {
            (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber)?.intValue
        }

        let cycles = intProp("CycleCount")
        let temp = intProp("Temperature").map { Double($0) / 100.0 } // centi-Celsius
        var health: Int? = nil
        if let design = intProp("DesignCapacity"), design > 0,
           let full = intProp("AppleRawMaxCapacity") ?? intProp("MaxCapacity") {
            health = Int((Double(full) / Double(design)) * 100)
        }
        return (cycles, health, temp)
    }
}
