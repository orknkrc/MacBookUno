import Foundation
import IOKit
import IOKit.hid
import LidAngleKit

let options = Options.parse(CommandLine.arguments)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func note(_ message: String) {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
}

// When stdout is not a terminal (e.g. `| tee log.txt`) overwriting the line makes no sense.
let usesInPlaceOutput = !options.forceLines && isatty(1) != 0 && !options.debug

// MARK: - --help

if case .help = options.mode {
    print(Options.helpText)
    exit(0)
}

// MARK: - --list

if case .list = options.mode {
    let devices = LidAngleSensor.findDevices(matching: options.match)
    if devices.isEmpty {
        note("No device matched: \(options.match.describedForHumans)")
        note("Try again with --any to match on usage alone.")
        exit(1)
    }
    print("Matched \(devices.count) device(s) (\(options.match.describedForHumans)):")
    for device in devices {
        if let sensor = try? LidAngleSensor(device: device) {
            print("  " + sensor.info.oneLine)
        } else {
            // Show devices whose descriptor could not be parsed too; the IDs still help.
            print("  (descriptor unreadable)")
        }
    }
    exit(0)
}

// MARK: - Locate and prepare the device

let located: (device: IOHIDDevice, usedFallback: Bool)
do {
    located = try LidAngleSensor.locate(preferred: options.match)
} catch {
    fail("\(error)")
}

if located.usedFallback {
    note("""
    WARNING: the VID/PID criteria did not match; the device was found by
    Usage Page 0x0020 / Usage 0x008A alone. VID/PID may differ on this model.
    Check the identifiers printed below.
    """)
}

let sensor: LidAngleSensor
do {
    sensor = try LidAngleSensor(device: located.device, overrideField: options.overrideField, preference: options.preference)
} catch {
    fail("\(error)")
}

print("Device: " + sensor.info.oneLine)

// MARK: - --descriptor

if case .descriptor = options.mode {
    let hex = sensor.descriptor.bytes.map { String(format: "%02X", $0) }.joined()
    print("\nRaw descriptor (\(sensor.descriptor.bytes.count) bytes):\n\(hex)")
    print("\nParsed fields:")
    print(sensor.descriptor.summary)
    print("\nAngle candidates:")
    for field in sensor.angleCandidates {
        print(String(format: "  Report ID %d, usage %@, bit %d..%d (%d bit), 0...%.2f degrees",
                     Int(field.reportID), field.usageDescription,
                     field.bitOffset, field.bitOffset + field.bitSize - 1,
                     field.bitSize, field.scaledMax))
    }
    print("\nSelected field: Report ID \(sensor.angleField.reportID), bit offset \(sensor.angleField.bitOffset), \(sensor.angleField.bitSize) bit")
    exit(0)
}

// MARK: - Open

do {
    try sensor.open()
} catch {
    fail("\(error)")
}
print("Device opened. Selected field: Report ID \(sensor.angleField.reportID), "
      + "payload bit \(sensor.angleField.bitOffset)..\(sensor.angleField.bitOffset + sensor.angleField.bitSize - 1) "
      + "(\(sensor.angleField.bitSize) bit), 0...\(String(format: "%.2f", sensor.angleField.scaledMax))°")

// MARK: - Debug helpers

/// Prints every plausible interpretation of the raw bytes as a table, so the
/// correct position can be found together when the angle is not where expected.
func candidateTable(_ bytes: [UInt8]) -> String {
    var lines: [String] = []
    let sizes = [8, 9, 12, 16]
    for byteOffset in 0..<bytes.count {
        var cells: [String] = []
        for size in sizes {
            let bitOffset = byteOffset * 8
            guard let v = HIDReportDescriptor.extract(bytes: bytes, bitOffset: bitOffset,
                                                      bitCount: size, signed: false) else {
                cells.append("    -")
                continue
            }
            // Mark values landing in 0...360: those are the angle candidates.
            let marker = (0...360).contains(v) ? "*" : " "
            cells.append(String(format: "%5d%@", v, marker))
        }
        lines.append("      byte \(byteOffset): " + zip(sizes, cells).map { "\($0)b=\($1)" }.joined(separator: "  "))
    }
    return lines.joined(separator: "\n")
}

var lastPrint = Date.distantPast
let printInterval = 1.0 / options.hz

func emit(_ reading: LidAngleReading) {
    guard Date().timeIntervalSince(lastPrint) >= printInterval else { return }
    lastPrint = Date()

    if options.debug {
        let idNote = reading.bufferIncludedReportID ? "buffer includes report ID" : "buffer is raw payload"
        if reading.angle.isNaN {
            print("[report \(reading.reportID)] (not the angle field) length=\(reading.rawReport.count) raw=[\(reading.hexReport)]")
        } else {
            print(String(format: "angle = %7.2f°  raw = %d  report %d  length %d  (%@)",
                         reading.angle, reading.rawValue, Int(reading.reportID),
                         reading.rawReport.count, idNote))
            print("      raw bytes: [\(reading.hexReport)]")
            print(candidateTable(reading.rawReport))
        }
    } else if usesInPlaceOutput {
        let bar = String(repeating: "#", count: max(0, min(40, Int(reading.angle / 9))))
        print(String(format: "\r  angle: %6.2f°  |%-40@|", reading.angle, bar as NSString), terminator: "")
        fflush(stdout)
    } else {
        print(String(format: "%@  %7.2f", ISO8601DateFormatter().string(from: reading.timestamp), reading.angle))
    }
}

// MARK: - --probe

if case .probe = options.mode {
    print("\n--- Trying read paths ---")

    // 1) Synchronous GetReport(Input)
    do {
        let reading = try sensor.readOnce()
        print(String(format: "1) GetReport(Input, id %d)  : WORKS — angle %.2f°, raw [%@]",
                     Int(sensor.angleField.reportID), reading.angle, reading.hexReport as NSString))
    } catch {
        print("1) GetReport(Input, id \(sensor.angleField.reportID))  : DOES NOT WORK")
        print("   \(error)".replacingOccurrences(of: "\n", with: "\n   "))
    }

    // 2) Input report stream — listen for 2 seconds
    print("2) Input report stream     : listening for 2 seconds...")
    var streamCount = 0
    var streamSample: LidAngleReading?
    sensor.forwardsAllReports = true
    do {
        try sensor.startStreaming { reading in
            streamCount += 1
            if streamSample == nil || !reading.angle.isNaN { streamSample = reading }
        }
    } catch {
        print("   could not start: \(error)")
    }
    CFRunLoopRunInMode(.defaultMode, 2.0, false)
    sensor.stopStreaming()
    sensor.forwardsAllReports = false
    if streamCount > 0, let sample = streamSample {
        print(String(format: "   WORKS — %d report(s) received, last angle %.2f°, raw [%@]",
                     streamCount, sample.angle, sample.hexReport as NSString))
    } else {
        print("   No reports arrived. The sensor may only publish when the angle changes —")
        print("   nudge the lid slightly and try again.")
    }

    // 3) Read through the element (IOHIDDeviceGetValue)
    let elementMatch: [String: Any] = [
        kIOHIDElementUsagePageKey: Int(sensor.angleField.usagePage),
        kIOHIDElementUsageKey: Int(sensor.angleField.usage),
    ]
    if let elements = IOHIDDeviceCopyMatchingElements(sensor.device, elementMatch as CFDictionary, 0) as? [IOHIDElement],
       let element = elements.first {
        // IOHIDDeviceGetValue expects a non-optional Unmanaged pointer; in Swift
        // we rebind the optional variable to supply one.
        var valueRef: Unmanaged<IOHIDValue>?
        let result = withUnsafeMutablePointer(to: &valueRef) { pointer in
            pointer.withMemoryRebound(to: Unmanaged<IOHIDValue>.self, capacity: 1) { rebound in
                IOHIDDeviceGetValue(sensor.device, element, rebound)
            }
        }
        if result == kIOReturnSuccess, let value = valueRef?.takeUnretainedValue() {
            let raw = IOHIDValueGetIntegerValue(value)
            print(String(format: "3) IOHIDDeviceGetValue      : WORKS — raw %ld, angle %.2f°",
                         raw, Double(raw) * sensor.angleField.scale))
        } else {
            print(String(format: "3) IOHIDDeviceGetValue      : DOES NOT WORK (IOReturn 0x%08X)", UInt32(bitPattern: result)))
        }
    } else {
        print("3) IOHIDDeviceGetValue      : no matching element")
    }

    sensor.close()
    exit(0)
}

// MARK: - Read loops

sensor.forwardsAllReports = options.allReports

func startPolling() {
    print("\nPolling mode (\(Int(options.hz)) Hz). Press Ctrl-C to stop.\n")
    var consecutiveFailures = 0
    let timer = Timer(timeInterval: printInterval, repeats: true) { _ in
        do {
            let reading = try sensor.readOnce()
            consecutiveFailures = 0
            lastPrint = .distantPast   // in polling mode, print every reading
            emit(reading)
        } catch {
            consecutiveFailures += 1
            if consecutiveFailures == 1 {
                note("\nRead error: \(error)")
            }
            if consecutiveFailures >= 10 {
                note("10 consecutive reads failed; exiting.")
                sensor.close()
                exit(1)
            }
        }
    }
    RunLoop.current.add(timer, forMode: .default)
}

func startStreamingMode(withFallback: Bool) {
    var receivedAny = false
    do {
        try sensor.startStreaming { reading in
            receivedAny = true
            emit(reading)
        }
    } catch {
        fail("\(error)")
    }
    print("\nStream mode — updates as the device publishes. Press Ctrl-C to stop.")
    print("(The sensor may only publish when the angle changes; if you see no numbers, nudge the lid.)\n")

    guard withFallback else { return }
    // Fall back to polling if no report arrives within 1.5 s.
    let fallback = Timer(timeInterval: 1.5, repeats: false) { _ in
        guard !receivedAny else { return }
        note("No reports during 1.5 s of streaming; switching to polling mode.")
        sensor.stopStreaming()
        startPolling()
    }
    RunLoop.current.add(fallback, forMode: .default)
}

switch options.mode {
case .poll:
    startPolling()
case .stream:
    startStreamingMode(withFallback: false)
default:
    startStreamingMode(withFallback: true)
}

// Leave the terminal clean on Ctrl-C.
signal(SIGINT) { _ in
    print("")
    exit(0)
}

RunLoop.current.run()
