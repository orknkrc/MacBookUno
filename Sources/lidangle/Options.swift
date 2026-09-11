import Foundation
import LidAngleKit

struct Options {
    enum Mode {
        case list        // list the HID devices matching the criteria
        case descriptor  // parse and print the report descriptor
        case probe       // try each read path once and report what works
        case stream      // listen to the input report stream
        case poll        // poll at 30 Hz via GetReport
        case auto        // stream first, fall back to polling if no data arrives
        case help
    }

    var mode: Mode = .auto
    var debug = false
    var allReports = false
    var hz: Double = 30
    var forceLines = false

    var vendorID: Int? = 0x05AC
    var productID: Int? = 0x8104
    var usagePage: Int? = 0x0020
    var usage: Int? = 0x008A

    // Manual field definition (an escape hatch if the descriptor is misparsed)
    var reportID: UInt8?
    var bitOffset: Int?
    var bitSize: Int?
    var signedField = false
    var exponent = 0
    /// --fine: select the finest-resolution angle field in the descriptor.
    var preference: LidAngleSensor.FieldPreference = .simple

    var match: LidAngleMatch {
        LidAngleMatch(vendorID: vendorID, productID: productID, usagePage: usagePage, usage: usage)
    }

    /// If all three are supplied, this field is used instead of the parsed one.
    var overrideField: HIDReportField? {
        guard let reportID, let bitOffset, let bitSize else { return nil }

        // The logical range is computed in Int arithmetic, so the widest sizes
        // have to be special-cased or they trap: unsigned 63 bits evaluates
        // `(1 << 63) - 1`, which is `Int.min - 1`, and signed 64 bits evaluates
        // `-(1 << 63)`, which is `-Int.min`. Both are overflows, not wrap-around.
        let logicalMin: Int
        let logicalMax: Int
        if signedField {
            logicalMin = bitSize >= 64 ? Int.min : -(1 << (bitSize - 1))
            logicalMax = bitSize >= 64 ? Int.max : (1 << (bitSize - 1)) - 1
        } else {
            logicalMin = 0
            logicalMax = bitSize >= 63 ? Int.max : (1 << bitSize) - 1
        }

        return HIDReportField(reportID: reportID, kind: .input,
                              usagePage: 0, usage: 0,
                              bitOffset: bitOffset, bitSize: bitSize,
                              logicalMin: logicalMin,
                              logicalMax: logicalMax,
                              unitExponent: exponent,
                              isConstant: false)
    }

    static func parse(_ arguments: [String]) -> Options {
        var options = Options()
        var index = 1
        let args = arguments

        func value(_ flag: String) -> String? {
            guard index + 1 < args.count else {
                FileHandle.standardError.write("Error: \(flag) expects a value.\n".data(using: .utf8)!)
                exit(2)
            }
            index += 1
            return args[index]
        }
        func intValue(_ flag: String) -> Int {
            let raw = value(flag) ?? ""
            let parsed: Int?
            if raw.lowercased().hasPrefix("0x") {
                parsed = Int(raw.dropFirst(2), radix: 16)
            } else {
                parsed = Int(raw)
            }
            guard let parsed else {
                FileHandle.standardError.write("Error: invalid number for \(flag): \(raw)\n".data(using: .utf8)!)
                exit(2)
            }
            return parsed
        }

        while index < args.count {
            switch args[index] {
            case "--version":
                print("lidangle \(ProjectVersion.current)")
                exit(0)
            case "--help", "-h":       options.mode = .help
            case "--list", "-l":       options.mode = .list
            case "--descriptor":       options.mode = .descriptor
            case "--probe":            options.mode = .probe
            case "--stream":           options.mode = .stream
            case "--poll":             options.mode = .poll
            case "--debug", "-d":      options.debug = true
            case "--all-reports":      options.allReports = true
            case "--lines":            options.forceLines = true
            case "--hz":               options.hz = Double(intValue("--hz"))
            case "--vid":              options.vendorID = intValue("--vid")
            case "--pid":              options.productID = intValue("--pid")
            case "--usage-page":       options.usagePage = intValue("--usage-page")
            case "--usage":            options.usage = intValue("--usage")
            case "--any":              options.vendorID = nil; options.productID = nil
            case "--report-id":        options.reportID = UInt8(truncatingIfNeeded: intValue("--report-id"))
            case "--bit-offset":       options.bitOffset = intValue("--bit-offset")
            case "--bit-size":
                let bits = intValue("--bit-size")
                guard (1...64).contains(bits) else {
                    FileHandle.standardError.write("Error: --bit-size must be between 1 and 64 (got \(bits))\n".data(using: .utf8)!)
                    exit(2)
                }
                options.bitSize = bits
            case "--exponent":         options.exponent = intValue("--exponent")
            case "--signed":           options.signedField = true
            case "--fine":             options.preference = .bestResolution
            case "--coarse":           options.preference = .simple
            default:
                FileHandle.standardError.write("Unknown option: \(args[index])  (try --help)\n".data(using: .utf8)!)
                exit(2)
            }
            index += 1
        }
        if options.hz <= 0 { options.hz = 30 }
        return options
    }

    static let helpText = """
    lidangle — MacBook lid angle sensor reader

    USAGE
      lidangle [options]

    MODES
      (default)         Listens to the input report stream first; if no data
                        arrives within 1.5 s it falls back to polling.
      --stream          Input report stream only (as the device publishes).
      --poll            Polling via IOHIDDeviceGetReport only.
      --probe           Opens the device, tries each read path once, prints results.
      --descriptor      Parses and prints the HID report descriptor, then exits.
      --list            Lists the HID devices matching the criteria, then exits.
      --help, -h        This text.
      --version         Print the version and exit.

    OUTPUT
      --debug, -d       Show raw report bytes and every plausible bit reading.
      --all-reports     Show every incoming report ID, not just the angle report.
      --hz N            N readings/lines per second (default 30).
      --lines           Print each reading on a new line instead of overwriting.

    DEVICE SELECTION (defaults verified on a Mac17,9)
      --vid 0x05AC      Vendor ID
      --pid 0x8104      Product ID
      --usage-page 0x20 Usage page (Sensor)
      --usage 0x8A      Usage (Orientation)
      --any             Drop the VID/PID criteria and match on usage alone.

    FIELD SELECTION
      --fine            Use the finest-resolution angle field (Report ID 7,
                        centidegrees on this Mac). Recommended for the effect.
      --coarse          The known whole-degree field (Report ID 1). Default.

    MANUAL FIELD DEFINITION (if the descriptor is misparsed)
      --report-id N --bit-offset N --bit-size N [--signed] [--exponent N]
      The bit offset is within the payload (excluding the report ID byte).

    EXAMPLES
      lidangle --descriptor
      lidangle --probe
      lidangle --debug --hz 10 --lines
      lidangle --fine --poll
    """
}
