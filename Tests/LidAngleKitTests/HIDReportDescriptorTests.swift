import XCTest
@testable import LidAngleKit

/// Tests for the descriptor parser and the angle field selection.
///
/// The fixture is the real 179-byte report descriptor read from the lid angle
/// sensor of a `Mac17,9` (`ioreg` / `IOHIDDeviceGetProperty("ReportDescriptor")`),
/// so these tests exercise the parser against actual hardware data without
/// needing the hardware.
final class HIDReportDescriptorTests: XCTestCase {

    private static let realDescriptorHex = """
    0520098AA10185010A7F044668013426680114750995018102651485020A0B0345FF3425FF14750895\
    0181028503 0A070347FFFFFF7F3427FFFFFF7F147520950181024701000000342701000000147508 \
    95018102 85040A030345033425031475089501810285050A840445023425021475089501810285060A \
    440545013425011475089501910285070A450547A08C00003427A08C00001475329501550E810285080A \
    4605450234250214750895018102C0
    """

    private static var realDescriptor: [UInt8] {
        let hex = realDescriptorHex.filter { !$0.isWhitespace }
        return stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: 2)
            return UInt8(hex[start..<end], radix: 16)!
        }
    }

    private func parsed() -> HIDReportDescriptor {
        HIDReportDescriptor(bytes: Self.realDescriptor)
    }

    // MARK: - Fixture sanity

    func testFixtureIsTheExpectedLength() {
        XCTAssertEqual(Self.realDescriptor.count, 179)
    }

    // MARK: - Parsing

    /// The whole-degree angle field. Report ID 1 carries a single 9-bit value at
    /// the start of the payload, ranging 0...360.
    func testParsesTheWholeDegreeAngleField() throws {
        let field = try XCTUnwrap(parsed().fields.first { $0.reportID == 1 && $0.kind == .input })
        XCTAssertEqual(field.usagePage, 0x0020)
        XCTAssertEqual(field.usage, 0x047F)
        XCTAssertEqual(field.bitOffset, 0)
        XCTAssertEqual(field.bitSize, 9, "9 bits, not the 16 usually quoted for this sensor")
        XCTAssertEqual(field.logicalMin, 0)
        XCTAssertEqual(field.logicalMax, 360)
        XCTAssertEqual(field.unitExponent, 0)
        XCTAssertFalse(field.isSigned)
        XCTAssertEqual(field.scaledMax, 360, accuracy: 0.0001)
    }

    /// The fine-resolution field. Report ID 7 is 0...36000 with unit exponent -2,
    /// i.e. hundredths of a degree, which is what the app uses.
    func testParsesTheCentidegreeAngleField() throws {
        let field = try XCTUnwrap(parsed().fields.first { $0.reportID == 7 && $0.kind == .input })
        XCTAssertEqual(field.usage, 0x0545)
        XCTAssertEqual(field.bitSize, 50)
        XCTAssertEqual(field.logicalMax, 36000)
        XCTAssertEqual(field.unitExponent, -2, "0x0E in the descriptor decodes to -2")
        XCTAssertEqual(field.scale, 0.01, accuracy: 0.000001)
        XCTAssertEqual(field.scaledMax, 360, accuracy: 0.0001)
    }

    /// Report ID 3 has two fields, so it pins the running bit offset: the second
    /// field must start where the first ends, not at zero.
    func testBitOffsetsAccumulateWithinAReport() {
        let fields = parsed().fields.filter { $0.reportID == 3 && $0.kind == .input }
        XCTAssertEqual(fields.count, 2)
        XCTAssertEqual(fields[0].bitOffset, 0)
        XCTAssertEqual(fields[0].bitSize, 32)
        XCTAssertEqual(fields[1].bitOffset, 32, "the second field follows the first")
        XCTAssertEqual(fields[1].bitSize, 8)
    }

    /// Each report ID gets its own payload, so offsets must restart per report.
    func testEachReportStartsItsOwnPayload() {
        let firstFields = Dictionary(grouping: parsed().fields.filter { $0.kind == .input },
                                     by: { $0.reportID })
            .compactMapValues { $0.min(by: { $0.bitOffset < $1.bitOffset }) }
        for (reportID, field) in firstFields {
            XCTAssertEqual(field.bitOffset, 0, "report \(reportID) must start at bit 0")
        }
    }

    /// Output items must not be mistaken for input items.
    func testDistinguishesOutputFromInput() throws {
        let output = try XCTUnwrap(parsed().fields.first { $0.kind == .output })
        XCTAssertEqual(output.reportID, 6)
        XCTAssertEqual(output.usage, 0x0544)
    }

    /// This sensor declares no feature items at all, which is why reading the
    /// angle as a feature report cannot work on this hardware.
    func testDescriptorContainsNoFeatureItems() {
        XCTAssertTrue(parsed().fields.filter { $0.kind == .feature }.isEmpty)
    }

    /// Logical min/max are signed per the HID spec: `25 FF` is -1, not 255.
    func testLogicalBoundsAreDecodedAsSigned() throws {
        let field = try XCTUnwrap(parsed().fields.first { $0.reportID == 2 && $0.kind == .input })
        XCTAssertEqual(field.logicalMin, 0)
        XCTAssertEqual(field.logicalMax, -1)
    }

    // MARK: - Field selection

    func testSimplePreferencePicksTheWholeDegreeField() throws {
        let field = try XCTUnwrap(LidAngleSensor.pickAngleField(from: parsed(), preference: .simple))
        XCTAssertEqual(field.reportID, 1)
        XCTAssertEqual(field.scale, 1, accuracy: 0.0001)
    }

    func testBestResolutionPreferencePicksTheCentidegreeField() throws {
        let field = try XCTUnwrap(LidAngleSensor.pickAngleField(from: parsed(), preference: .bestResolution))
        XCTAssertEqual(field.reportID, 7, "0.01 degree steps beat 1 degree steps")
        XCTAssertEqual(field.scale, 0.01, accuracy: 0.000001)
    }

    /// Only the two angle-shaped fields should be offered as candidates; the
    /// status and counter fields in the same descriptor must not be.
    func testOnlyAngleShapedFieldsAreCandidates() {
        let candidates = LidAngleSensor.angleCandidates(in: parsed())
        XCTAssertEqual(Set(candidates.map(\.reportID)), [1, 7])
    }

    func testReturnsNilWhenThereIsNoAngleField() {
        // Usage page 0x0001 (Generic Desktop), a plain 8-bit input, no angle.
        let bytes: [UInt8] = [0x05, 0x01, 0x09, 0x30, 0xA1, 0x01,
                              0x15, 0x00, 0x25, 0x7F, 0x75, 0x08, 0x95, 0x01, 0x81, 0x02, 0xC0]
        let descriptor = HIDReportDescriptor(bytes: bytes)
        XCTAssertNil(LidAngleSensor.pickAngleField(from: descriptor, preference: .simple))
    }

    // MARK: - Bit extraction

    /// The exact bytes this sensor returns for a 112 degree lid angle:
    /// report ID, then the 9-bit value packed LSB-first.
    func testExtractsTheRealAngleReading() {
        let report: [UInt8] = [0x01, 0x70, 0x00]
        let value = HIDReportDescriptor.extract(bytes: report, bitOffset: 8, bitCount: 9, signed: false)
        XCTAssertEqual(value, 112)
    }

    /// HID packs fields LSB-first and they may straddle byte boundaries.
    func testExtractsAcrossAByteBoundary() {
        // 0b1_0000_0001 starting at bit 4 of 0x10, 0x02 -> bits 4...12
        let bytes: [UInt8] = [0x10, 0x02]
        XCTAssertEqual(HIDReportDescriptor.extract(bytes: bytes, bitOffset: 4, bitCount: 9, signed: false), 33)
    }

    func testSignExtendsWhenAsked() {
        let bytes: [UInt8] = [0xFF]
        XCTAssertEqual(HIDReportDescriptor.extract(bytes: bytes, bitOffset: 0, bitCount: 8, signed: true), -1)
        XCTAssertEqual(HIDReportDescriptor.extract(bytes: bytes, bitOffset: 0, bitCount: 8, signed: false), 255)
    }

    /// Reading past the end must fail rather than return garbage, because the
    /// device can send shorter reports than the descriptor declares.
    func testRefusesToReadPastTheEnd() {
        let bytes: [UInt8] = [0x01, 0x70]
        XCTAssertNil(HIDReportDescriptor.extract(bytes: bytes, bitOffset: 8, bitCount: 16, signed: false))
        XCTAssertNil(HIDReportDescriptor.extract(bytes: bytes, bitOffset: -1, bitCount: 8, signed: false))
        XCTAssertNil(HIDReportDescriptor.extract(bytes: bytes, bitOffset: 0, bitCount: 0, signed: false))
    }
}
