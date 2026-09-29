import Foundation
import WalletCore
import XCTest
@testable import LightningCore

final class BIP353Tests: XCTestCase, @unchecked Sendable {
    private struct Vector: Decodable { let name: String, proof: String, now: UInt64 }
    private func vector(_ number: Int) throws -> Vector {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "proof-\(number)", withExtension: "json", subdirectory: "Vectors/BIP353"))
        return try JSONDecoder().decode(Vector.self, from: Data(contentsOf: url))
    }
    func testPublishedProofValidatesRootRSAAndDelegatedP256Locally() async throws {
        let value = try vector(1), name = try BIP353Name(value.name)
        let validator = DNSSECValidator(records: try DNSSECWire.proof(XCTUnwrap(Data(hex: value.proof))), now: value.now)
        let (records, ttl) = try await validator.txt(name: name.queryName)
        XCTAssertEqual(records.count, 2); XCTAssertEqual(ttl, 30)
        XCTAssertTrue(records.contains { String(decoding: $0, as: UTF8.self).hasPrefix("bitcoin:") })
        let zones = await validator.verifiedZones()
        XCTAssertTrue(zones.contains("."))
        let stale = DNSSECValidator(records: try DNSSECWire.proof(XCTUnwrap(Data(hex: value.proof))), now: value.now + 365 * 86_400)
        do { _ = try await stale.txt(name: name.queryName); XCTFail() } catch {}
    }
    func testPublishedCrossDomainWildcardCNAMERequiresSignedNonExistenceProof() async throws {
        let value = try vector(3), name = try BIP353Name(value.name), proof = try XCTUnwrap(Data(hex: value.proof))
        let instructions = try await BIP353Resolver.resolveProof(proof, name: name, chain: NetworkParams.mainnet.genesisHash, now: value.now)
        XCTAssertTrue(instructions.uri.hasPrefix("bitcoin:")); XCTAssertEqual(instructions.offer.paths.count, 1)
        XCTAssertLessThanOrEqual(instructions.validUntil, value.now + 30)
        let missing = try vector(5)
        do { _ = try await BIP353Resolver.resolveProof(XCTUnwrap(Data(hex: missing.proof)), name: name, chain: NetworkParams.mainnet.genesisHash, now: value.now); XCTFail("A wildcard signature must not replace proof that a closer name is absent") } catch {}
    }
    func testPublishedAmbiguousPaymentRecordsAndCorruptProofAreRejected() async throws {
        let value = try vector(4), name = try BIP353Name(value.name), proof = try XCTUnwrap(Data(hex: value.proof))
        do { _ = try await BIP353Resolver.resolveProof(proof, name: name, chain: NetworkParams.mainnet.genesisHash, now: value.now); XCTFail() }
        catch { XCTAssertEqual(error as? DNSSECError, .ambiguous) }
        var records = try DNSSECWire.proof(proof)
        let index = try XCTUnwrap(records.firstIndex(where: { $0.type == 16 }))
        let record = records[index]
        records[index] = .init(name: record.name, type: record.type, dnsClass: record.dnsClass, ttl: record.ttl, data: record.data + Data([0]))
        let validator = DNSSECValidator(records: records, now: value.now)
        do { _ = try await validator.txt(name: name.queryName); XCTFail() } catch {}
    }
    func testNameParsingPreservesSignedDNSLabelsAndRejectsConfusableInput() throws {
        XCTAssertEqual(try BIP353Name("₿Alice@Example.COM").display, "₿alice@example.com")
        XCTAssertEqual(try BIP353Name("a.b@dnssec_proof_tests.bitcoin.ninja").user, "a.b")
        for invalid in ["alice@@example.com", "аlice@example.com", "alice@localhost", "a@-example.com", "a@foo..com", "a/b@example.com"] {
            XCTAssertThrowsError(try BIP353Name(invalid), invalid)
        }
    }
    func testDNSCompressionCyclesAndMalformedTXTLengthsAreRejected() throws {
        var reader = DNSSECWire.Reader(Data([0xc0, 0x00]))
        XCTAssertThrowsError(try reader.name())
        XCTAssertThrowsError(try DNSSECWire.proof(Data([1, 97])))
        let query = try DNSSECWire.query(name: "alice.user._bitcoin-payment.example.com.", type: 16, id: 42)
        XCTAssertThrowsError(try DNSSECWire.response(query, name: "alice.user._bitcoin-payment.example.com.", type: 16, id: 42))
    }
}

