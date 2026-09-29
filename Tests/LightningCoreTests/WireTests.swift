import Foundation
import XCTest
@testable import LightningCore

final class WireTests: XCTestCase {
    func testShutdownWitnessProgramsRespectNegotiationAndExactPushLength() {
        for size in [20, 32] {
            XCTAssertTrue(ChannelTerms.validShutdown(Data([0, UInt8(size)]) + Data(repeating: 1, count: size)))
        }
        for version in UInt8(0x51)...0x60 {
            for size in [2, 32, 40] {
                let script = Data([version, UInt8(size)]) + Data(repeating: 1, count: size)
                XCTAssertFalse(ChannelTerms.validShutdown(script))
                XCTAssertTrue(ChannelTerms.validShutdown(script, anySegwit: true))
            }
        }
        for script in [Data(), Data([0]), Data([0, 2, 1, 1]), Data([0x51, 1, 1]),
                       Data([0x50, 2, 1, 1]), Data([0x51, 3, 1, 1]), Data([0x51, 2, 1, 1, 1]),
                       Data([0x51, 41]) + Data(repeating: 1, count: 41)] {
            XCTAssertFalse(ChannelTerms.validShutdown(script, anySegwit: true))
        }
    }
    func testBigSizeBoundariesAndCanonicalEncoding() throws {
        let vectors: [(UInt64, String)] = [(0, "00"), (252, "fc"), (253, "fd00fd"), (65535, "fdffff"),
            (65536, "fe00010000"), (4_294_967_295, "feffffffff"), (4_294_967_296, "ff0000000100000000"),
            (.max, "ffffffffffffffffff")]
        for (number, encoded) in vectors {
            var writer = LightningWire.Writer(); writer.bigSize(number)
            XCTAssertEqual(writer.data, try hex(encoded))
            var reader = LightningWire.Reader(writer.data); XCTAssertEqual(try reader.bigSize(), number); try reader.requireEnd()
        }
        for encoded in ["fd00fc", "fe0000ffff", "ff00000000ffffffff", "fd", "fe0000", "ff000000"] {
            var reader = try LightningWire.Reader(hex(encoded)); XCTAssertThrowsError(try reader.bigSize())
        }
    }
    func testTLVRejectsUnknownRequiredDuplicatesOrderAndOverflow() throws {
        for encoded in ["0200", "01000100", "03000100", "01ffffffffffffffffff", "010201"] {
            var reader = try LightningWire.Reader(hex(encoded)); XCTAssertThrowsError(try reader.tlvs(known: []))
        }
        var reader = try LightningWire.Reader(hex("01000302abcd"))
        XCTAssertEqual(try reader.tlvs(known: []), [.init(type: 1, value: Data()), .init(type: 3, value: try hex("abcd"))])
    }
    func testFeaturesAndSlicedMessages() throws {
        XCTAssertEqual(LightningFeatures.channelOpening.bits, [1, 9, 13, 15, 23, 27, 45])
        XCTAssertEqual(LightningFeatures.asyncClient.bits, [1, 9, 13, 15, 23, 25, 27, 39, 45])
        XCTAssertTrue(LightningFeatures.asyncClient.supports(26))
        XCTAssertTrue(LightningFeatures.asyncClient.supports(38))
        XCTAssertFalse(LightningFeatures.channelOpening.supports(38))
        let message = try LightningFeatures.channelOpening.initialization()
        XCTAssertEqual(try LightningFeatures.readInitialization(message), .channelOpening)
        let required = try LightningFeatures(bits: [12, 44])
        try required.validateRequired(supported: [12, 44])
        XCTAssertThrowsError(try required.validateRequired(supported: [12]))
        XCTAssertThrowsError(try LightningFeatures(bits: [12, 13]).validateRequired(supported: [12]))
        let padded = Data([0xff]) + message.bytes
        XCTAssertEqual(try LightningWire.Message(bytes: padded.dropFirst()), message)
        XCTAssertThrowsError(try LightningWire.Message(bytes: Data([0])))
        XCTAssertThrowsError(try LightningWire.Message(type: 1, payload: Data(repeating: 0, count: 65_534)))
    }
}
