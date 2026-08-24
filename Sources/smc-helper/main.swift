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
//   smc-helper hold <fanId> <rpm> <seconds>     diagnostic: keep the SMC
//                                               connection open while manual,
//                                               sampling continuously
//   smc-helper serve                            long-running mode: hold the
//                                               SMC connection and take
//                                               commands on stdin
//
// Why `serve` exists: on modern macOS the firmware honors manual fan control
// only while the client's SMC connection stays open — the moment it closes,
// every fan snaps back to automatic. (Verified empirically: a held connection
// drives the fan within ~2s; the identical writes from a short-lived process
// are reverted before they can even be read back.) So real control requires a
// resident process, which is what other fan tools' daemons are for.

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
        // Order matters: while a fan is in automatic mode the firmware keeps
        // rewriting its target, so a target written first is overwritten
        // before it can take effect — every write looks silently discarded.
        // Take manual control first, then set the target. The brief window in
        // manual with the previous target is harmless: that target is the
        // firmware's own last value, i.e. the fan's current speed.
        do {
            try smc.write("F\(index)Md", bytes: [1])
        } catch {
            fail("Failed to put Fan \(index) into manual mode: \(error)")
        }
        if let rpm {
            do {
                try smc.writeNumber("F\(index)Tg", value: rpm)
            } catch {
                try? smc.write("F\(index)Md", bytes: [0])
                fail("Failed to set Fan \(index) target: \(error)")
            }
            // Verify both writes: an SMC that quietly ignores them must not be
            // reported as success, or the fan silently stops following its
            // rule. On refusal, hand the fan back to the firmware.
            let readBack = smc.readFloat("F\(index)Tg") ?? -1
            guard abs(readBack - rpm) <= max(50, rpm * 0.05) else {
                try? smc.write("F\(index)Md", bytes: [0])
                fail("Fan \(index): asked for \(Int(rpm)) RPM but the SMC reports \(Int(readBack)) — returned to automatic")
            }
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
      smc-helper serve                        resident mode: hold the SMC
                                              connection, read commands on
                                              stdin (set/auto/reset/ping/quit)
      smc-helper hold <fanId> <rpm> <secs>    diagnostic: hold and sample
    """)
    exit(0)
}

let smc = openSMC()

switch arguments[1] {
case "get":
    printFans(smc)
case "reset":
    resetAll(smc)
case "hold":
    // Diagnostic for firmwares that appear to discard writes: some may only
    // honor manual control while the client connection stays open, reverting
    // the moment it closes. Short-lived invocations can never observe that —
    // this holds the connection and samples, then hands the fan back.
    guard arguments.count >= 5, let id = Int(arguments[2]),
          let rpm = Double(arguments[3]), let seconds = Int(arguments[4]),
          seconds <= 60 else {
        fail("Usage: smc-helper hold <fanId> <rpm> <seconds<=60>")
    }
    try? smc.write("F\(id)Md", bytes: [1])
    try? smc.writeNumber("F\(id)Tg", value: rpm)
    for tick in 0..<(seconds * 2) {
        let md = (try? smc.read("F\(id)Md"))?.bytes.first ?? 255
        let tg = smc.readFloat("F\(id)Tg") ?? -1
        let ac = smc.readFloat("F\(id)Ac") ?? -1
        print("t=\(Double(tick) / 2)s Md=\(md) Tg=\(Int(tg)) actual=\(Int(ac))")
        // Re-assert each second in case the firmware decays the values.
        if tick % 2 == 1 {
            try? smc.write("F\(id)Md", bytes: [1])
            try? smc.writeNumber("F\(id)Tg", value: rpm)
        }
        usleep(500_000)
    }
    try? smc.write("F\(id)Md", bytes: [0])
    print("DONE: Fan \(id) returned to automatic")
case "serve":
    // Line protocol on stdin:
    //   set <fanId> <rpm>    take manual control of one fan
    //   auto <fanId>         hand one fan back to the firmware
    //   reset                hand every fan back
    //   quit                 reset + exit
    // EOF — the app died — resets every fan: a crashed app must never leave
    // fans pinned. Desired targets are re-asserted every 2 seconds because
    // the writes are asynchronous and the firmware can decay them.
    final class ServeState: @unchecked Sendable {
        var desired: [Int: Double] = [:]
        let lock = NSLock()
    }
    let state = ServeState()
    let smcQueue = DispatchQueue(label: "smc.serial")

    let reassert = DispatchSource.makeTimerSource(queue: smcQueue)
    reassert.schedule(deadline: .now() + 2, repeating: 2)
    reassert.setEventHandler {
        state.lock.lock(); let wanted = state.desired; state.lock.unlock()
        for (id, rpm) in wanted {
            try? smc.write("F\(id)Md", bytes: [1])
            try? smc.writeNumber("F\(id)Tg", value: rpm)
        }
    }
    reassert.resume()

    print("READY")
    fflush(stdout)

    while let line = readLine(strippingNewline: true) {
        let parts = line.split(separator: " ").map(String.init)
        guard let command = parts.first else { continue }
        var reply = "ERR"
        smcQueue.sync {
            switch command {
            case "set" where parts.count >= 3:
                if let id = Int(parts[1]), let rpm = Double(parts[2]),
                   id >= 0, id < fanCount(smc) {
                    try? smc.write("F\(id)Md", bytes: [1])
                    try? smc.writeNumber("F\(id)Tg", value: rpm)
                    state.lock.lock(); state.desired[id] = rpm; state.lock.unlock()
                    reply = "OK set \(id) \(Int(rpm))"
                }
            case "auto" where parts.count >= 2:
                if let id = Int(parts[1]) {
                    try? smc.write("F\(id)Md", bytes: [0])
                    state.lock.lock(); state.desired[id] = nil; state.lock.unlock()
                    reply = "OK auto \(id)"
                }
            case "reset", "quit":
                for i in 0..<fanCount(smc) { try? smc.write("F\(i)Md", bytes: [0]) }
                state.lock.lock(); state.desired = [:]; state.lock.unlock()
                reply = "OK \(command)"
            case "ping":
                reply = "OK ping"
            default:
                reply = "ERR unknown"
            }
        }
        print(reply)
        fflush(stdout)
        if command == "quit" { smc.close(); exit(0) }
    }
    // stdin closed — the app is gone. Never leave fans pinned.
    smcQueue.sync {
        for i in 0..<fanCount(smc) { try? smc.write("F\(i)Md", bytes: [0]) }
    }
    smc.close()
    exit(0)
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
