import Foundation
import IOKit
import IOKit.hid

/// Device matching criteria. The defaults are the real values verified on this
/// Mac (Mac17,9) with `hidutil list` and `ioreg`; all of them are optional and
/// overridable so other models can differ.
public struct LidAngleMatch: Sendable {
    public var vendorID: Int?
    public var productID: Int?
    public var usagePage: Int?
    public var usage: Int?

    public init(vendorID: Int? = 0x05AC,
                productID: Int? = 0x8104,
                usagePage: Int? = 0x0020,
                usage: Int? = 0x008A) {
        self.vendorID = vendorID
        self.productID = productID
        self.usagePage = usagePage
        self.usage = usage
    }

    /// A looser criterion that only looks at the sensor/orientation usage, so the
    /// device can still be found on models where VID/PID differ.
    public static let usageOnly = LidAngleMatch(vendorID: nil, productID: nil,
                                                usagePage: 0x0020, usage: 0x008A)

    var dictionary: [String: Any] {
        var dict: [String: Any] = [:]
        if let vendorID { dict[kIOHIDVendorIDKey] = vendorID }
        if let productID { dict[kIOHIDProductIDKey] = productID }
        if let usagePage { dict[kIOHIDPrimaryUsagePageKey] = usagePage }
        if let usage { dict[kIOHIDPrimaryUsageKey] = usage }
        return dict
    }

    public var describedForHumans: String {
        var parts: [String] = []
        if let vendorID { parts.append(String(format: "VID 0x%04X", vendorID)) }
        if let productID { parts.append(String(format: "PID 0x%04X", productID)) }
        if let usagePage { parts.append(String(format: "UsagePage 0x%04X", usagePage)) }
        if let usage { parts.append(String(format: "Usage 0x%04X", usage)) }
        return parts.isEmpty ? "(no criteria)" : parts.joined(separator: ", ")
    }
}

/// A single reading.
public struct LidAngleReading: Sendable {
    public let angle: Double
    public let rawValue: Int
    public let rawReport: [UInt8]
    public let reportID: UInt8
    /// Was the first byte of the raw buffer the report ID? (Auto-detected.)
    public let bufferIncludedReportID: Bool
    public let timestamp: Date

    public var hexReport: String {
        rawReport.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

/// Device identity information (for listing and diagnostics).
public struct LidAngleDeviceInfo: Sendable {
    public let vendorID: Int
    public let productID: Int
    public let usagePage: Int
    public let usage: Int
    public let product: String
    public let manufacturer: String
    public let transport: String
    public let maxInputReportSize: Int
    public let maxFeatureReportSize: Int
    public let maxOutputReportSize: Int
    public let descriptorByteCount: Int

    public var oneLine: String {
        String(format: "VID 0x%04X  PID 0x%04X  UsagePage 0x%04X  Usage 0x%04X  \"%@\" / \"%@\"  transport=%@  maxIn=%d maxFeat=%d maxOut=%d  descriptor=%d bytes",
               vendorID, productID, usagePage, usage,
               manufacturer, product, transport,
               maxInputReportSize, maxFeatureReportSize, maxOutputReportSize,
               descriptorByteCount)
    }
}

/// Finds, opens and reads the lid angle sensor.
///
/// Completely UI-independent: it does not import AppKit and knows nothing about
/// displays. The menu bar app uses this class as-is.
public final class LidAngleSensor {

    public let device: IOHIDDevice
    public let info: LidAngleDeviceInfo
    public let descriptor: HIDReportDescriptor

    /// The angle field selected from the descriptor. It can also be supplied
    /// from outside via `--report-id/--bit-offset`.
    public private(set) var angleField: HIDReportField

    /// Dummy buffer handed to IOKit when removing the input report callback.
    ///
    /// Per instance rather than static: a shared mutable global is not
    /// concurrency-safe (an error under the Swift 6 language mode), and one byte
    /// per sensor costs nothing. Freed in `deinit`, after `stopStreaming()`.

    private let nullBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)

    private var isOpen = false
    private var inputBuffer: UnsafeMutablePointer<UInt8>?
    private var inputBufferSize: Int = 0
    private var streamHandler: ((LidAngleReading) -> Void)?
    private var scheduledRunLoop: CFRunLoop?

    // MARK: - Discovery

    /// Returns every HID device matching the criteria. May be empty.
    public static func findDevices(matching match: LidAngleMatch) -> [IOHIDDevice] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let dict = match.dictionary
        IOHIDManagerSetDeviceMatching(manager, dict.isEmpty ? nil : (dict as CFDictionary))
        guard let set = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        return Array(set)
    }

    /// Tries the narrow criteria first, then the loose one, and reports which
    /// matched. We never guess: a loose match is signalled back to the caller.
    public static func locate(preferred: LidAngleMatch) throws -> (device: IOHIDDevice, usedFallback: Bool) {
        if let device = findDevices(matching: preferred).first {
            return (device, false)
        }
        // The narrow criteria did not match: VID/PID may differ on this model.
        // The sensor usage is standard, so retry with that alone.
        if let device = findDevices(matching: .usageOnly).first {
            return (device, true)
        }
        throw LidAngleError.deviceNotFound(searched: preferred.describedForHumans)
    }

    // MARK: - Setup

    public init(device: IOHIDDevice,
                overrideField: HIDReportField? = nil,
                preference: FieldPreference = .simple) throws {
        self.device = device
        self.info = LidAngleSensor.readInfo(device)

        guard let data = IOHIDDeviceGetProperty(device, "ReportDescriptor" as CFString) as? Data else {
            throw LidAngleError.noDescriptor
        }
        self.descriptor = HIDReportDescriptor(bytes: [UInt8](data))

        if let overrideField {
            self.angleField = overrideField
        } else if let picked = LidAngleSensor.pickAngleField(from: descriptor, preference: preference) {
            self.angleField = picked
        } else {
            throw LidAngleError.noAngleField
        }
    }

    /// Which angle field to prefer.
    public enum FieldPreference: Sendable {
        /// The known "whole degrees" field (usage 0x047F).
        case simple
        /// The finest-resolution field. On this Mac that is Report ID 7
        /// (centidegrees); needed to keep the fold transition smooth.
        case bestResolution
    }

    /// Selects the angle field from the descriptor.
    ///
    /// Candidate pool: input fields whose scaled upper bound is around 360 (plus
    /// the known usage 0x047F). `.simple` picks the known field;
    /// `.bestResolution` picks the one with the smallest step (most negative
    /// unit exponent).
    public static func pickAngleField(from descriptor: HIDReportDescriptor,
                                      preference: FieldPreference = .simple) -> HIDReportField? {
        let candidates = angleCandidates(in: descriptor)
        guard !candidates.isEmpty else { return nil }

        switch preference {
        case .simple:
            if let exact = candidates.first(where: { $0.usagePage == 0x0020 && $0.usage == 0x047F }) {
                return exact
            }
            return candidates.min(by: { $0.bitSize < $1.bitSize })

        case .bestResolution:
            // A smaller scale is finer: exp -2 -> 0.01 degree steps.
            return candidates.min(by: { lhs, rhs in
                lhs.scale == rhs.scale ? lhs.bitSize < rhs.bitSize : lhs.scale < rhs.scale
            })
        }
    }

    /// Input fields that could be an angle: those whose scaled max is around 360.
    public static func angleCandidates(in descriptor: HIDReportDescriptor) -> [HIDReportField] {
        descriptor.fields.filter {
            $0.kind == .input && !$0.isConstant && $0.bitSize > 0 &&
            ((300.0...400.0).contains($0.scaledMax) || ($0.usagePage == 0x0020 && $0.usage == 0x047F))
        }
    }

    /// Every possible angle field (to show them all in debug mode).
    public var angleCandidates: [HIDReportField] {
        LidAngleSensor.angleCandidates(in: descriptor)
    }

    public func useField(_ field: HIDReportField) {
        angleField = field
    }

    // MARK: - Open / close

    public func open() throws {
        guard !isOpen else { return }
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else { throw LidAngleError.openFailed(result) }
        isOpen = true
    }

    public func close() {
        guard isOpen else { return }
        stopStreaming()
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        isOpen = false
    }

    deinit {
        stopStreaming()
        if isOpen { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
        // After stopStreaming(), so the buffer is still valid while IOKit is
        // handed it to clear the callback.
        nullBuffer.deallocate()
    }

    // MARK: - Synchronous reads (polling)

    /// A one-shot read via `IOHIDDeviceGetReport(kIOHIDReportTypeInput, ...)`.
    /// Not supported on every model; if it fails, fall back to streaming.
    public func readOnce() throws -> LidAngleReading {
        guard isOpen else { throw LidAngleError.notOpen }

        let reportID = angleField.reportID
        // Report ID byte + payload; never smaller than the device's declared max.
        let capacity = max(info.maxInputReportSize, angleField.minimumPayloadBytes + 1) + 8
        var buffer = [UInt8](repeating: 0, count: capacity)
        var length = CFIndex(capacity)

        let result = buffer.withUnsafeMutableBufferPointer { ptr -> IOReturn in
            ptr[0] = reportID
            return IOHIDDeviceGetReport(device, kIOHIDReportTypeInput, CFIndex(reportID), ptr.baseAddress!, &length)
        }
        guard result == kIOReturnSuccess else {
            throw LidAngleError.reportFailed(reportID: reportID, result)
        }

        let received = Array(buffer.prefix(max(0, Int(length))))
        guard let reading = decode(report: received, reportID: reportID, reportLength: received.count) else {
            throw LidAngleError.decodeFailed(raw: received, reportID: reportID)
        }
        return reading
    }

    // MARK: - Streaming (input report callback)

    /// `handler` is called as the device publishes reports, on the given run loop.
    public func startStreaming(on runLoop: CFRunLoop = CFRunLoopGetCurrent(),
                               handler: @escaping (LidAngleReading) -> Void) throws {
        guard isOpen else { throw LidAngleError.notOpen }
        stopStreaming()

        streamHandler = handler
        // Slightly larger than the device declares, so short reports cannot overflow.
        inputBufferSize = max(info.maxInputReportSize, angleField.minimumPayloadBytes + 1) + 32
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: inputBufferSize)
        buffer.initialize(repeating: 0, count: inputBufferSize)
        inputBuffer = buffer

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, buffer, CFIndex(inputBufferSize), { ctx, result, _, _, reportID, report, reportLength in
            guard result == kIOReturnSuccess, let ctx else { return }
            let sensor = Unmanaged<LidAngleSensor>.fromOpaque(ctx).takeUnretainedValue()
            let length = max(0, Int(reportLength))
            let bytes = Array(UnsafeBufferPointer(start: report, count: length))
            sensor.handleInputReport(bytes: bytes, reportID: UInt8(truncatingIfNeeded: reportID), reportLength: length)
        }, context)

        IOHIDDeviceScheduleWithRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
        scheduledRunLoop = runLoop
    }

    public func stopStreaming() {
        if let runLoop = scheduledRunLoop {
            // Removing the callback also requires a valid buffer; we use the
            // persistent one-byte buffer so each stop does not leak.
            IOHIDDeviceRegisterInputReportCallback(device, nullBuffer, 1, nil, nil)
            IOHIDDeviceUnscheduleFromRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
            scheduledRunLoop = nil
        }
        streamHandler = nil
        if let inputBuffer {
            inputBuffer.deinitialize(count: inputBufferSize)
            inputBuffer.deallocate()
            self.inputBuffer = nil
            inputBufferSize = 0
        }
    }

    /// In debug mode we may want to see report IDs we do not otherwise care about.
    public var forwardsAllReports = false

    private func handleInputReport(bytes: [UInt8], reportID: UInt8, reportLength: Int) {
        guard let handler = streamHandler else { return }
        if reportID != angleField.reportID && !forwardsAllReports { return }

        if reportID == angleField.reportID,
           let reading = decode(report: bytes, reportID: reportID, reportLength: reportLength) {
            handler(reading)
        } else if forwardsAllReports {
            // Forward undecodable reports raw as well: useful in debug mode.
            handler(LidAngleReading(angle: .nan, rawValue: 0, rawReport: bytes,
                                    reportID: reportID, bufferIncludedReportID: false,
                                    timestamp: Date()))
        }
    }

    // MARK: - Decoding

    /// Converts a raw report into an angle.
    ///
    /// Whether the first byte of the buffer is the report ID varies in IOKit, so
    /// we try both interpretations and keep the one that lands inside the
    /// logical range. "Try both possibilities, keep the valid one" is more
    /// robust than hard-coding the offset.
    public func decode(report: [UInt8], reportID: UInt8, reportLength: Int) -> LidAngleReading? {
        let bytes = Array(report.prefix(reportLength))
        let field = angleField
        let range = field.logicalMin...max(field.logicalMin, field.logicalMax)
        let availableBits = bytes.count * 8

        // The device can send a shorter report than the descriptor declares: on
        // this Mac report 7 claims "50 bit" but a 4-byte payload arrives. HID
        // fields are packed LSB-first, so reading the available low bits still
        // gives the right value (it already fits in 16 bits); hence we clamp the
        // field to the bits actually present.
        func clampedSize(from offset: Int) -> Int {
            max(0, min(field.bitSize, availableBits - offset))
        }

        // Candidate 1: the buffer starts with the report ID byte -> shift by 8 bits.
        let sizeWithID = clampedSize(from: field.bitOffset + 8)
        let withID = sizeWithID >= 8
            ? HIDReportDescriptor.extract(bytes: bytes, bitOffset: field.bitOffset + 8,
                                          bitCount: sizeWithID, signed: field.isSigned && sizeWithID == field.bitSize)
            : nil
        // Candidate 2: the buffer is the payload itself.
        let sizeWithoutID = clampedSize(from: field.bitOffset)
        let withoutID = sizeWithoutID >= 8
            ? HIDReportDescriptor.extract(bytes: bytes, bitOffset: field.bitOffset,
                                          bitCount: sizeWithoutID, signed: field.isSigned && sizeWithoutID == field.bitSize)
            : nil

        let firstByteLooksLikeID = bytes.first == reportID
        var chosen: (value: Int, includedID: Bool)?

        if firstByteLooksLikeID, let withID, range.contains(withID) {
            chosen = (withID, true)
        } else if let withoutID, range.contains(withoutID) {
            chosen = (withoutID, false)
        } else if let withID, range.contains(withID) {
            chosen = (withID, true)
        }

        guard let chosen else { return nil }
        return LidAngleReading(angle: Double(chosen.value) * field.scale,
                               rawValue: chosen.value,
                               rawReport: bytes,
                               reportID: reportID,
                               bufferIncludedReportID: chosen.includedID,
                               timestamp: Date())
    }

    // MARK: - Property reads

    private static func readInfo(_ device: IOHIDDevice) -> LidAngleDeviceInfo {
        func int(_ key: String) -> Int {
            (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? 0
        }
        func string(_ key: String) -> String {
            (IOHIDDeviceGetProperty(device, key as CFString) as? String) ?? "-"
        }
        let descriptorBytes = (IOHIDDeviceGetProperty(device, "ReportDescriptor" as CFString) as? Data)?.count ?? 0

        return LidAngleDeviceInfo(
            vendorID: int(kIOHIDVendorIDKey),
            productID: int(kIOHIDProductIDKey),
            usagePage: int(kIOHIDPrimaryUsagePageKey),
            usage: int(kIOHIDPrimaryUsageKey),
            product: string(kIOHIDProductKey),
            manufacturer: string(kIOHIDManufacturerKey),
            transport: string(kIOHIDTransportKey),
            maxInputReportSize: int(kIOHIDMaxInputReportSizeKey),
            maxFeatureReportSize: int(kIOHIDMaxFeatureReportSizeKey),
            maxOutputReportSize: int(kIOHIDMaxOutputReportSizeKey),
            descriptorByteCount: descriptorBytes
        )
    }
}
