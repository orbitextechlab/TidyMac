import Foundation
import IOKit

/// Low-level interface to the Apple System Management Controller (SMC).
///
/// The SMC exposes hardware sensors (temperature, voltage, current) and fan
/// controls through a small set of IOKit "struct" calls. The key/data layout
/// used here is the long-standing reverse-engineered format shared by tools
/// such as smcFanControl and iStat; it is stable across Intel and Apple
/// Silicon Macs (Apple Silicon simply exposes a different set of keys).
///
/// Reading keys never requires elevated privileges. Writing keys (fan control)
/// generally requires the process to run as root, which is why fan overrides
/// are routed through the bundled `smc-helper` executed with admin rights.
final class SMCKit {

    // MARK: - Errors

    enum SMCError: Error, CustomStringConvertible {
        case driverNotFound
        case failedToOpen(kern_return_t)
        case keyNotFound(String)
        case callFailed(kern_return_t, UInt8)
        case unsupportedType(String, String)

        var description: String {
            switch self {
            case .driverNotFound: return "AppleSMC device not found"
            case .failedToOpen(let r): return "IOServiceOpen failed (0x\(String(r, radix: 16)))"
            case .keyNotFound(let k): return "SMC key not found: \(k)"
            case .callFailed(let r, let c): return "SMC call failed (kr=0x\(String(r, radix: 16)), result=\(c))"
            case .unsupportedType(let k, let t): return "Don't know how to write \(k) (type '\(t)')"
            }
        }
    }

    // MARK: - Data structures (mirror the AppleSMC kernel structs)

    private struct SMCKeyDataVers {
        var major: UInt8 = 0
        var minor: UInt8 = 0
        var build: UInt8 = 0
        var reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    private struct SMCKeyDataPLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }

    private struct SMCKeyDataKeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }

    /// 32 inline bytes of value payload. Must be a fixed-size tuple (not a
    /// Swift Array) so the struct's memory layout matches the kernel's
    /// SMCKeyData_t when passed to IOConnectCallStructMethod.
    private typealias SMCBytes32 = (
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
        UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

    private struct SMCKeyData {
        var key: UInt32 = 0
        var vers = SMCKeyDataVers()
        var pLimitData = SMCKeyDataPLimitData()
        var keyInfo = SMCKeyDataKeyInfo()
        // AppleSMC expects the C layout where sizeof(keyInfo) is padded to 12
        // bytes. Swift embeds nested structs by size (9), not stride, so pad
        // explicitly to keep the total struct at exactly 80 bytes.
        var keyInfoPadding1: UInt8 = 0
        var keyInfoPadding2: UInt8 = 0
        var keyInfoPadding3: UInt8 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: SMCBytes32 = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                                 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    /// Decoded value for a single SMC key.
    struct Value {
        let key: String
        let dataType: String   // e.g. "flt ", "fpe2", "ui8 "
        let dataSize: UInt32
        let bytes: [UInt8]
    }

    private enum Selector: UInt8 {
        case readBytes = 5
        case writeBytes = 6
        case readKeyFromIndex = 8
        case readKeyInfo = 9
    }

    // MARK: - Connection state

    private var connection: io_connect_t = 0

    // MARK: - Lifecycle

    func open() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                  IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.driverNotFound }
        defer { IOObjectRelease(service) }

        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == kIOReturnSuccess else { throw SMCError.failedToOpen(result) }
    }

    func close() {
        if connection != 0 {
            IOServiceClose(connection)
            connection = 0
        }
    }

    deinit { close() }

    // MARK: - Public reads

    /// Read and decode a key such as "TC0P" (CPU proximity temperature).
    func read(_ key: String) throws -> Value {
        let info = try readKeyInfo(key)
        var input = SMCKeyData()
        input.key = Self.fourCharCode(key)
        input.keyInfo.dataSize = info.dataSize
        input.data8 = Selector.readBytes.rawValue

        let output = try call(input)
        let bytes = withUnsafeBytes(of: output.bytes) { raw -> [UInt8] in
            Array(raw.prefix(Int(info.dataSize)))
        }
        return Value(key: key,
                     dataType: Self.fourCharString(info.dataType),
                     dataSize: info.dataSize,
                     bytes: bytes)
    }

    /// Convenience: decode a key as a temperature/RPM float. Returns nil if the
    /// key is absent or the type is unrecognised.
    func readFloat(_ key: String) -> Double? {
        guard let value = try? read(key) else { return nil }
        return Self.decodeFloat(value)
    }

    /// Total number of keys the SMC currently exposes.
    func keyCount() throws -> Int {
        let value = try read("#KEY")
        guard value.bytes.count >= 4 else { return 0 }
        return Int(UInt32(value.bytes[0]) << 24 | UInt32(value.bytes[1]) << 16 |
                   UInt32(value.bytes[2]) << 8 | UInt32(value.bytes[3]))
    }

    /// The key at a position in the SMC's internal table.
    func key(atIndex index: Int) throws -> String {
        var input = SMCKeyData()
        input.data8 = Selector.readKeyFromIndex.rawValue
        input.data32 = UInt32(index)
        return Self.fourCharString(try call(input).key)
    }

    /// Every key the SMC exposes. Used to discover sensors without hardcoding a
    /// per-model table; a handful of indices can fail on some Macs, so failures
    /// are skipped rather than aborting the sweep.
    func allKeys() -> [String] {
        guard let count = try? keyCount(), count > 0 else { return [] }
        return (0..<count).compactMap { try? key(atIndex: $0) }
    }

    // MARK: - Public writes (require root)

    /// Write a number to a key using whatever encoding that key actually uses.
    ///
    /// This matters: the fan target key `F{n}Tg` is `fpe2` (2 bytes) on Intel
    /// Macs but `flt` (4 bytes) on Apple Silicon. Writing fpe2 bytes into a
    /// float key leaves the top two bytes zero, which the SMC reads back as a
    /// target of ~0 — the fan then sits at its minimum no matter how hot the
    /// machine gets, and the write reports no error at all.
    func writeNumber(_ key: String, value: Double) throws {
        let info = try readKeyInfo(key)
        let type = Self.fourCharString(info.dataType).trimmingCharacters(in: .whitespaces)
        let bytes: [UInt8]

        switch type {
        case "flt":
            // decodeFloat reads this little-endian, so write it the same way.
            let bits = Float(value).bitPattern
            bytes = [UInt8(bits & 0xff), UInt8((bits >> 8) & 0xff),
                     UInt8((bits >> 16) & 0xff), UInt8((bits >> 24) & 0xff)]
        case "fpe2":
            let raw = UInt16(max(0, min(65535, value * 4)))
            bytes = [UInt8(raw >> 8), UInt8(raw & 0xff)]
        case "ui8":
            bytes = [UInt8(max(0, min(255, value)))]
        case "ui16":
            let raw = UInt16(max(0, min(65535, value)))
            bytes = [UInt8(raw >> 8), UInt8(raw & 0xff)]
        default:
            throw SMCError.unsupportedType(key, type)
        }
        try write(key, bytes: bytes)
    }

    /// Write raw bytes to a key. Used by the privileged helper for fan control.
    func write(_ key: String, bytes: [UInt8]) throws {
        let info = try readKeyInfo(key)
        var input = SMCKeyData()
        input.key = Self.fourCharCode(key)
        input.keyInfo.dataSize = info.dataSize
        input.data8 = Selector.writeBytes.rawValue
        withUnsafeMutableBytes(of: &input.bytes) { raw in
            for (i, b) in bytes.prefix(Int(info.dataSize)).enumerated() { raw[i] = b }
        }
        _ = try call(input)
    }

    // MARK: - Private plumbing

    /// A key's size and type never change while the machine is running, so the
    /// lookup is cached — it otherwise doubles the IOKit round-trips of every
    /// single read, which is significant when polling many sensors.
    private var keyInfoCache: [String: SMCKeyDataKeyInfo] = [:]

    private func readKeyInfo(_ key: String) throws -> SMCKeyDataKeyInfo {
        if let cached = keyInfoCache[key] { return cached }
        var input = SMCKeyData()
        input.key = Self.fourCharCode(key)
        input.data8 = Selector.readKeyInfo.rawValue
        let output = try call(input)
        if output.result == 132 { throw SMCError.keyNotFound(key) } // kSMCKeyNotFound
        keyInfoCache[key] = output.keyInfo
        return output.keyInfo
    }

    private func call(_ inputStruct: SMCKeyData) throws -> SMCKeyData {
        guard connection != 0 else { throw SMCError.driverNotFound }
        var input = inputStruct
        var output = SMCKeyData()
        var outputSize = MemoryLayout<SMCKeyData>.stride

        let kr = IOConnectCallStructMethod(
            connection,
            UInt32(2), // kSMCHandleYPCEvent
            &input, MemoryLayout<SMCKeyData>.stride,
            &output, &outputSize)

        guard kr == kIOReturnSuccess else { throw SMCError.callFailed(kr, output.result) }
        guard output.result == 0 else {
            if output.result == 132 { throw SMCError.keyNotFound(Self.fourCharString(input.key)) }
            throw SMCError.callFailed(kr, output.result)
        }
        return output
    }

    // MARK: - Encoding helpers

    static func fourCharCode(_ s: String) -> UInt32 {
        let chars = Array(s.utf8)
        var code: UInt32 = 0
        for i in 0..<4 {
            code <<= 8
            code |= UInt32(i < chars.count ? chars[i] : 0)
        }
        return code
    }

    static func fourCharString(_ code: UInt32) -> String {
        let bytes = [UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff),
                     UInt8((code >> 8) & 0xff), UInt8(code & 0xff)]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    /// Decode common SMC numeric types into a Double.
    static func decodeFloat(_ value: Value) -> Double? {
        let b = value.bytes
        switch value.dataType.trimmingCharacters(in: .whitespaces) {
        case "flt":
            guard b.count >= 4 else { return nil }
            let bits = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
            return Double(Float(bitPattern: bits))
        case "fpe2": // unsigned fixed-point, 2 fractional bits (used for fan RPM)
            guard b.count >= 2 else { return nil }
            let raw = UInt16(b[0]) << 8 | UInt16(b[1])
            return Double(raw) / 4.0
        case "fp88": // signed fixed-point, 8 fractional bits
            guard b.count >= 2 else { return nil }
            let raw = Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))
            return Double(raw) / 256.0
        case "ui8":
            guard b.count >= 1 else { return nil }
            return Double(b[0])
        case "ui16":
            guard b.count >= 2 else { return nil }
            return Double(UInt16(b[0]) << 8 | UInt16(b[1]))
        case "ui32":
            guard b.count >= 4 else { return nil }
            return Double(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
        case "si8":
            guard b.count >= 1 else { return nil }
            return Double(Int8(bitPattern: b[0]))
        default:
            return nil
        }
    }
}
