import CryptoKit
import Foundation
import WalletCore
import XCTest
@testable import LightningCore

final class DNSSECPrimitiveTests: XCTestCase, @unchecked Sendable {
    private let now: UInt64 = 100
    private func keyBytes(algorithm: UInt8, material: Data) -> Data { Data([1, 1, 3, algorithm]) + material }
    private func signed(_ records: [DNSSECWire.Record], key: DNSSECSignature.Key,
                        sign: (Data) throws -> Data) throws -> DNSSECWire.Record {
        let first = try XCTUnwrap(records.first)
        var header = LightningWire.Writer(); header.u16(first.type); header.u8(key.algorithm)
        header.u8(UInt8(first.name.split(separator: ".").count)); header.u32(60); header.u32(1000); header.u32(50); header.u16(key.tag)
        header.append(try DNSSECWire.nameData("."))
        let body = try records.sorted { $0.data.lexicographicallyPrecedes($1.data) }.map { record -> Data in
            var writer = LightningWire.Writer(); writer.append(try DNSSECWire.nameData(record.name)); writer.u16(record.type); writer.u16(1)
            writer.u32(60); writer.u16(UInt16(record.data.count)); writer.append(record.data); return writer.data
        }.reduce(Data(), +)
        return .init(name: first.name, type: 46, dnsClass: 1, ttl: 60, data: try header.data + sign(header.data + body))
    }
    private func anchor(_ key: DNSSECSignature.Key) -> Data {
        var writer = LightningWire.Writer(); writer.u16(key.tag); writer.u8(key.algorithm); writer.u8(2)
        writer.append(Data(SHA256.hash(data: Data([0]) + key.bytes))); return writer.data
    }
    func testDNAMEAndUntrustedFetchValidateThroughAnExplicitTestRoot() async throws {
        let privateKey = P256.Signing.PrivateKey(), key = try DNSSECSignature.Key(keyBytes(algorithm: 13, material: privateKey.publicKey.x963Representation.dropFirst()))
        let signing: (Data) throws -> Data = { try privateKey.signature(for: $0).rawRepresentation }
        let dnskey = DNSSECWire.Record(name: ".", type: 48, dnsClass: 1, ttl: 60, data: key.bytes)
        let alias = DNSSECWire.Record(name: "user._bitcoin-payment.example.com.", type: 39, dnsClass: 1, ttl: 60, data: try DNSSECWire.nameData("pay.example.net."))
        let uri = Data("bitcoin:?lno=unused".utf8)
        let target = DNSSECWire.Record(name: "alice.pay.example.net.", type: 16, dnsClass: 1, ttl: 60, data: Data([UInt8(uri.count)]) + uri)
        let records = try [dnskey, signed([dnskey], key: key, sign: signing), alias, signed([alias], key: key, sign: signing),
                           target, signed([target], key: key, sign: signing)]
        let validator = DNSSECValidator(now: now, fetch: { _, _ in records }, trustAnchors: [anchor(key)])
        let (resolved, ttl) = try await validator.txt(name: "alice.user._bitcoin-payment.example.com.")
        XCTAssertEqual(resolved, [uri]); XCTAssertEqual(ttl, 60)
        let untrusted = DNSSECValidator(records: records, now: now)
        do { _ = try await untrusted.txt(name: "alice.user._bitcoin-payment.example.com."); XCTFail("An arbitrary resolver key never replaces the IANA root") } catch {}
    }
    func testP384AndEd25519SignaturesAndDSBindingsRejectDamageAndSHA1Signatures() throws {
        let record = DNSSECWire.Record(name: "test.example.", type: 16, dnsClass: 1, ttl: 60, data: Data([1, 97]))
        let p384 = P384.Signing.PrivateKey(), ed25519 = Curve25519.Signing.PrivateKey()
        let keys = try [DNSSECSignature.Key(keyBytes(algorithm: 14, material: p384.publicKey.x963Representation.dropFirst())),
                        DNSSECSignature.Key(keyBytes(algorithm: 15, material: ed25519.publicKey.rawRepresentation))]
        let signatures: [(Data) throws -> Data] = [{ try p384.signature(for: $0).rawRepresentation }, { try ed25519.signature(for: $0) }]
        for index in keys.indices {
            let signed = try signed([record], key: keys[index], sign: signatures[index])
            let signature = try DNSSECSignature.Signature(signed.data)
            XCTAssertEqual(try DNSSECSignature.verify(signature, key: keys[index], records: [record], now: now), 60)
            var damaged = signed.data; damaged[damaged.count - 1] ^= 1
            XCTAssertThrowsError(try DNSSECSignature.verify(.init(damaged), key: keys[index], records: [record], now: now))
            XCTAssertTrue(try DNSSECSignature.matchesDS(anchor(keys[index]), key: keys[index], zone: "."))
            XCTAssertFalse(try DNSSECSignature.matchesDS(anchor(keys[index]), key: keys[index], zone: "example."))
            var ds = LightningWire.Writer(); ds.u16(keys[index].tag); ds.u8(keys[index].algorithm); ds.u8(4)
            ds.append(Data(SHA384.hash(data: Data([0]) + keys[index].bytes)))
            XCTAssertTrue(try DNSSECSignature.matchesDS(ds.data, key: keys[index], zone: "."))
        }
        let weak = try DNSSECSignature.Key(keyBytes(algorithm: 5, material: Data(repeating: 1, count: 128)))
        let signature = try DNSSECSignature.Signature(signed([record], key: weak, sign: { _ in Data(repeating: 1, count: 128) }).data)
        XCTAssertThrowsError(try DNSSECSignature.verify(signature, key: weak, records: [record], now: now))
        XCTAssertThrowsError(try DNSSECSignature.Key(Data([0, 0, 3, 13]) + Data(repeating: 1, count: 64)))
    }
    func testWireCompressionCanonicalizesAliasesAndBoundsEveryLength() throws {
        let original = try DNSSECWire.nameData("Example.COM.")
        var reader = DNSSECWire.Reader(original + Data([0xc0, 0]))
        reader.offset = original.count
        XCTAssertEqual(try reader.name(), "example.com."); XCTAssertEqual(reader.offset, original.count + 2)
        for bytes in [Data([0xc0]), Data([0x40]), Data([1, 92, 0]), Data([1]), Data([0xc0, 0])] {
            var reader = DNSSECWire.Reader(bytes); XCTAssertThrowsError(try reader.name())
        }
        XCTAssertThrowsError(try DNSSECWire.nameData("missing-trailing-dot"))
        XCTAssertThrowsError(try DNSSECWire.nameData(String(repeating: "a", count: 64) + "."))
        var response = try DNSSECWire.query(name: "example.com.", type: 16, id: 42)
        response[2] = 0x81; response[3] = 0x80
        // The sole OPT record is not a signed payment instruction.
        XCTAssertTrue(try DNSSECWire.response(response, name: "example.com.", type: 16, id: 42).isEmpty)
        XCTAssertThrowsError(try DNSSECWire.response(response, name: "other.com.", type: 16, id: 42))
    }
}
