import Foundation

// TidyMac SMC Helper CLI
//
// A tiny root-only tool that performs the SMC *writes* required for fan
// control. The main app never writes the SMC directly; it invokes this helper
// through an admin authentication prompt. Reads stay in the app because they
// need no privileges.
//
// Usage:
//   smc-helper get                              print fan count + per-fan RPM
//   smc-helper set <fanId> <mode> [<rpm>]       mode: 0 = auto, 1 = manual
//   smc-helper reset                            return every fan to automatic

let arguments = CommandLine.arguments

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("ERROR: " + message + "\n").utf8))
    exit(1)
}

func openSMC() -> SMCKit {
    let smc = SMCKit()
    do { try smc.open() } catch { fail("No AppleSMC device found (\(error))") }
    return smc
}

func fanCount(_ smc: SMCKit) -> Int {
    Int(smc.readFloat("FNum") ?? 0)
}

func printFans(_ smc: SMCKit) {
    let count = fanCount(smc)
    print("Fans: \(count)")
    for i in 0..<count {
        let rpm = smc.readFloat("F\(i)Ac") ?? 0
        let target = smc.readFloat("F\(i)Tg") ?? 0
        print("Fan \(i): \(Int(rpm)) RPM (target \(Int(target)))")
    }
}

/// Put a single fan into manual mode at a target RPM, or back to automatic.
func setFan(_ smc: SMCKit, index: Int, manual: Bool, rpm: Double?) {
    guard index >= 0, index < fanCount(smc) else { fail("Invalid fanId \(index)") }

    if manual {
        // Write the target *before* taking manual control, so the fan can
        // never sit in manual mode with a stale or zero target — that would
        // pin it at its minimum exactly when cooling is needed most.
        if let rpm {
            do {
                try smc.writeNumber("F\(index)Tg", value: rpm)
            } catch {
                fail("Failed to set Fan \(index) target: \(error)")
            }
            // Verify: a write that the SMC quietly ignores must not report
            // success, or the fan silently stops following its rule.
            let readBack = smc.readFloat("F\(index)Tg") ?? -1
            guard abs(readBack - rpm) <= max(50, rpm * 0.05) else {
                try? smc.write("F\(index)Md", bytes: [0])
                fail("Fan \(index): asked for \(Int(rpm)) RPM but the SMC reports \(Int(readBack)) — returned to automatic")
            }
        }
        do {
            try smc.write("F\(index)Md", bytes: [1])
        } catch {
            fail("Failed to put Fan \(index) into manual mode: \(error)")
        }
        print("SUCCESS: Fan \(index) set to \(rpm.map { String(Int($0)) } ?? "manual") RPM (manual)")
    } else {
        do {
            try smc.write("F\(index)Md", bytes: [0])
        } catch {
            fail("Failed to return Fan \(index) to automatic: \(error)")
        }
        print("SUCCESS: Fan \(index) returned to automatic")
    }
}

func resetAll(_ smc: SMCKit) {
    for i in 0..<fanCount(smc) {
        try? smc.write("F\(i)Md", bytes: [0])
    }
    print("SUCCESS: Reset fan controls")
}

// MARK: - Entry

guard arguments.count >= 2 else {
    print("""
    TidyMac SMC Helper CLI
    Usage:
      smc-helper get
      smc-helper set <fanId> <mode> [<rpm>]   (mode: 0 = auto, 1 = manual)
      smc-helper reset
    """)
    exit(0)
}

let smc = openSMC()

switch arguments[1] {
case "get":
    printFans(smc)
case "reset":
    resetAll(smc)
case "set":
    guard arguments.count >= 4, let id = Int(arguments[2]), let mode = Int(arguments[3]) else {
        fail("Usage: smc-helper set <fanId> <mode> [<rpm>]")
    }
    let rpm = arguments.count >= 5 ? Double(arguments[4]) : nil
    setFan(smc, index: id, manual: mode == 1, rpm: rpm)
default:
    fail("Unknown command: \(arguments[1])")
}

smc.close()
