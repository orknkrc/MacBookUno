import Foundation

/// The "main item" kinds in a HID report descriptor.
public enum HIDReportKind: String, Sendable {
    case input, output, feature
}

/// A single data field parsed out of the descriptor.
///
/// `bitOffset` is within the **payload**, i.e. it excludes the report ID byte.
/// If the buffer coming from the device includes the report ID, the reader side
/// adds 8 bits.
public struct HIDReportField: Sendable {
    public let reportID: UInt8
    public let kind: HIDReportKind
    public let usagePage: UInt32
    public let usage: UInt32
    public let bitOffset: Int
    public let bitSize: Int
    public let logicalMin: Int
    public let logicalMax: Int
    public let unitExponent: Int
    public let isConstant: Bool

    public init(reportID: UInt8, kind: HIDReportKind, usagePage: UInt32, usage: UInt32,
                bitOffset: Int, bitSize: Int, logicalMin: Int, logicalMax: Int,
                unitExponent: Int, isConstant: Bool) {
        self.reportID = reportID
        self.kind = kind
        self.usagePage = usagePage
        self.usage = usage
        self.bitOffset = bitOffset
        self.bitSize = bitSize
        self.logicalMin = logicalMin
        self.logicalMax = logicalMax
        self.unitExponent = unitExponent
        self.isConstant = isConstant
    }

    /// A negative logical minimum means the field is signed.
    public var isSigned: Bool { logicalMin < 0 }

    /// The HID "unit exponent" is base 10: exp = -2 means the raw value is in centidegrees.
    public var scale: Double { pow(10.0, Double(unitExponent)) }

    /// Scaled upper bound. Around 360 means the field is very likely an angle.
    public var scaledMax: Double { Double(logicalMax) * scale }

    /// Smallest payload length (in bytes) needed to read this field.
    public var minimumPayloadBytes: Int { (bitOffset + bitSize + 7) / 8 }

    public var usageDescription: String {
        String(format: "0x%04X:0x%04X", usagePage, usage)
    }
}

/// A hand-written, dependency-free HID report descriptor parser.
///
/// Why we have our own: IOKit's `Elements` dictionary does not expose bit
/// offsets. Deriving the offset from the descriptor instead of hard-coding it
/// lets the tool find the right byte on other MacBook models too.
public struct HIDReportDescriptor: Sendable {
    public let fields: [HIDReportField]
    public let bytes: [UInt8]

    /// Global items are stacked with Push/Pop, hence a separate struct.
    private struct GlobalState {
        var usagePage: UInt32 = 0
        var logicalMin: Int = 0
        var logicalMax: Int = 0
        var unitExponent: Int = 0
        var reportSize: Int = 0
        var reportCount: Int = 0
        var reportID: UInt8 = 0
    }

    public init(bytes: [UInt8]) {
        self.bytes = bytes

        var fields: [HIDReportField] = []
        var global = GlobalState()
        var globalStack: [GlobalState] = []
        var localUsages: [UInt32] = []
        // A separate bit cursor per (reportID, kind): each report has its own payload.
        var bitCursor: [String: Int] = [:]

        var i = 0
        while i < bytes.count {
            let prefix = bytes[i]
            i += 1

            // Long item (0xFE): unused in practice, so we skip it.
            if prefix == 0xFE {
                guard i + 1 < bytes.count else { break }
                let dataSize = Int(bytes[i])
                i += 2 + dataSize
                continue
            }

            let tag = (prefix >> 4) & 0x0F
            let type = (prefix >> 2) & 0x03
            let rawSize = Int(prefix & 0x03)
            let size = rawSize == 3 ? 4 : rawSize

            guard i + size <= bytes.count else { break }
            let data = Array(bytes[i..<(i + size)])
            i += size

            let unsigned = HIDReportDescriptor.unsignedValue(data)
            let signed = HIDReportDescriptor.signedValue(data)

            switch type {
            case 0: // Main
                switch tag {
                case 0x8, 0x9, 0xB:
                    let kind: HIDReportKind = tag == 0x8 ? .input : (tag == 0x9 ? .output : .feature)
                    let isConstant = (unsigned & 0x01) != 0
                    let key = "\(global.reportID)/\(kind.rawValue)"
                    var offset = bitCursor[key] ?? 0

                    for n in 0..<max(global.reportCount, 0) {
                        // If the usage list is shorter than ReportCount, the last
                        // usage repeats (HID spec behavior).
                        let usageEntry: UInt32
                        if localUsages.isEmpty {
                            usageEntry = 0
                        } else if n < localUsages.count {
                            usageEntry = localUsages[n]
                        } else {
                            usageEntry = localUsages[localUsages.count - 1]
                        }

                        // A 4-byte usage item carries the page as well.
                        let page = usageEntry > 0xFFFF ? (usageEntry >> 16) : global.usagePage
                        let usage = usageEntry > 0xFFFF ? (usageEntry & 0xFFFF) : usageEntry

                        fields.append(HIDReportField(
                            reportID: global.reportID,
                            kind: kind,
                            usagePage: page,
                            usage: usage,
                            bitOffset: offset,
                            bitSize: global.reportSize,
                            logicalMin: global.logicalMin,
                            logicalMax: global.logicalMax,
                            unitExponent: global.unitExponent,
                            isConstant: isConstant
                        ))
                        offset += global.reportSize
                    }
                    bitCursor[key] = offset
                    localUsages.removeAll()

                case 0xA: // Collection
                    localUsages.removeAll()
                case 0xC: // End Collection
                    localUsages.removeAll()
                default:
                    localUsages.removeAll()
                }

            case 1: // Global
                switch tag {
                case 0x0: global.usagePage = UInt32(unsigned)
                case 0x1: global.logicalMin = signed
                case 0x2: global.logicalMax = signed
                case 0x5: global.unitExponent = HIDReportDescriptor.decodeUnitExponent(unsigned)
                case 0x7: global.reportSize = Int(unsigned)
                case 0x8: global.reportID = UInt8(truncatingIfNeeded: unsigned)
                case 0x9: global.reportCount = Int(unsigned)
                case 0xA: globalStack.append(global)
                case 0xB: if let popped = globalStack.popLast() { global = popped }
                default: break
                }

            case 2: // Local
                if tag == 0x0 { localUsages.append(UInt32(truncatingIfNeeded: unsigned)) }

            default:
                break
            }
        }

        self.fields = fields
    }

    // MARK: - Helpers

    private static func unsignedValue(_ data: [UInt8]) -> UInt64 {
        var v: UInt64 = 0
        for (index, byte) in data.enumerated() { v |= UInt64(byte) << (8 * UInt64(index)) }
        return v
    }

    /// Logical/Physical min-max are signed per the HID spec.
    private static func signedValue(_ data: [UInt8]) -> Int {
        guard let last = data.last, !data.isEmpty else { return 0 }
        var v = unsignedValue(data)
        if last & 0x80 != 0 {
            let bits = UInt64(data.count * 8)
            if bits < 64 { v |= ~UInt64(0) << bits }
            return Int(bitPattern: UInt(v))
        }
        return Int(v)
    }

    /// 4-bit nibble: 0...7 are positive, 8...15 map to -8...-1.
    private static func decodeUnitExponent(_ raw: UInt64) -> Int {
        let nibble = Int(raw & 0x0F)
        return nibble > 7 ? nibble - 16 : nibble
    }

    // MARK: - Bit extraction

    /// Reads an LSB-first packed field out of a byte array (the HID packing rule).
    public static func extract(bytes: [UInt8], bitOffset: Int, bitCount: Int, signed: Bool) -> Int? {
        guard bitCount > 0, bitCount <= 64, bitOffset >= 0 else { return nil }
        guard bitOffset + bitCount <= bytes.count * 8 else { return nil }

        var value: UInt64 = 0
        for n in 0..<bitCount {
            let bit = bitOffset + n
            let bitValue = (bytes[bit >> 3] >> UInt8(bit & 7)) & 1
            value |= UInt64(bitValue) << UInt64(n)
        }

        if signed, bitCount < 64, value & (1 << UInt64(bitCount - 1)) != 0 {
            return Int(bitPattern: UInt(value | (~UInt64(0) << UInt64(bitCount))))
        }
        return Int(value)
    }
}

public extension HIDReportDescriptor {
    /// Human-readable summary (used by --descriptor in the CLI).
    var summary: String {
        var lines: [String] = []
        let grouped = Dictionary(grouping: fields, by: { "\($0.reportID)/\($0.kind.rawValue)" })
        for key in grouped.keys.sorted() {
            guard let group = grouped[key] else { continue }
            let first = group[0]
            lines.append("Report ID \(first.reportID) (\(first.kind.rawValue)):")
            for f in group {
                let signedText = f.isSigned ? "signed" : "unsigned"
                let expText = f.unitExponent == 0 ? "" : String(format: ", exp 10^%d -> max %.2f", f.unitExponent, f.scaledMax)
                let constText = f.isConstant ? ", constant" : ""
                lines.append(String(format: "  usage %@  bit %3d..%-3d (%2d bit, %@)  logical %d...%d%@%@",
                                    f.usageDescription,
                                    f.bitOffset, f.bitOffset + f.bitSize - 1,
                                    f.bitSize, signedText,
                                    f.logicalMin, f.logicalMax,
                                    expText, constText))
            }
        }
        return lines.joined(separator: "\n")
    }
}
