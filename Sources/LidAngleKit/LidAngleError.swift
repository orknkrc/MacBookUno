import Foundation
import IOKit

/// Errors the sensor layer can raise. Each carries a message that can be shown
/// to a user as-is and says what to do next.
public enum LidAngleError: Error, CustomStringConvertible {
    case deviceNotFound(searched: String)
    case openFailed(IOReturn)
    case notOpen
    case reportFailed(reportID: UInt8, IOReturn)
    case noDescriptor
    case noAngleField
    case decodeFailed(raw: [UInt8], reportID: UInt8)

    public var description: String {
        switch self {
        case .deviceNotFound(let searched):
            return """
            Lid angle sensor not found (searched for: \(searched)).
            Check with: `hidutil list | grep -i 8104`  and  `ioreg -l | grep -i MagAlpha`
            This Mac may not have the sensor at all (Mac mini/Studio, or an older model).
            """

        case .openFailed(let code):
            switch code {
            case IOReturn(bitPattern: 0xE00002E2): // kIOReturnNotPermitted
                return """
                Could not open the device: permission denied (kIOReturnNotPermitted).
                Grant Terminal (or this binary) access under System Settings >
                Privacy & Security > Input Monitoring, then restart the program.
                """
            case IOReturn(bitPattern: 0xE00002C5): // kIOReturnExclusiveAccess
                return """
                Could not open the device: another process holds it exclusively.
                Another copy of this tool may already be running.
                """
            case IOReturn(bitPattern: 0xE00002C0): // kIOReturnNoDevice
                return "Could not open the device: it disappeared (kIOReturnNoDevice). This can happen around sleep; try again."
            default:
                return String(format: "Could not open the device. IOReturn = 0x%08X", UInt32(bitPattern: code))
            }

        case .notOpen:
            return "The device is not open; call open() first."

        case .reportFailed(let reportID, let code):
            return String(format: """
                Could not read report ID %d. IOReturn = 0x%08X
                On this sensor the angle is published as an INPUT report; synchronous
                reads (GetReport) may not be supported on every model. Try `--stream`.
                """, Int(reportID), UInt32(bitPattern: code))

        case .noDescriptor:
            return "Could not read the device's HID report descriptor (no ReportDescriptor property)."

        case .noAngleField:
            return """
            No angle field found in the report descriptor.
            Dump the descriptor with `--descriptor` and specify the field manually
            using `--report-id/--bit-offset/--bit-size`.
            """

        case .decodeFailed(let raw, let reportID):
            let hex = raw.map { String(format: "%02X", $0) }.joined(separator: " ")
            return "Could not decode report ID \(reportID); fewer bytes arrived than expected. Raw: [\(hex)]"
        }
    }
}
