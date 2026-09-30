import CryptoKit
import Foundation
import WalletCore

extension DNSSECValidator {
    /// A wildcard signature alone proves only the wildcard exists. A signed
    /// denial must also prove that no closer name overrides it (RFC4035/5155).
    func validateWildcard(owner: String, signature: DNSSECSignature.Signature) async throws {
        let labels = owner.split(separator: ".")
        guard Int(signature.labels) < labels.count else { return }
        let nextCloser = labels.suffix(Int(signature.labels) + 1).joined(separator: ".") + "."
        let denials = records.filter { [47, 50].contains($0.type) && DNSSECWire.subdomain($0.name, of: signature.signer) }
        for record in denials {
            let covers = record.type == 47 ? (try? Self.nsecCovers(record, name: nextCloser)) : (try? Self.nsec3Covers(record, name: nextCloser, zone: signature.signer))
            let signedByZone = selected(record.name, type: 46).contains {
                guard let proof = try? DNSSECSignature.Signature($0.data) else { return false }
                return proof.covered == record.type && proof.signer == signature.signer && Int(proof.labels) == record.name.split(separator: ".").count
            }
            guard covers == true, signedByZone else { continue }
            do { try await validate(selected(record.name, type: record.type)); return } catch { continue }
        }
        throw DNSSECError.unauthenticated
    }
    static func nsecCovers(_ record: DNSSECWire.Record, name: String) throws -> Bool {
        var reader = DNSSECWire.Reader(record.data)
        let next = try reader.name()
        return nameInterval(Self.canonicalName(record.name), Self.canonicalName(next), Self.canonicalName(name))
    }
    private static func canonicalName(_ name: String) -> [String] { name.split(separator: ".").reversed().map(String.init) }
    private static func nameInterval(_ start: [String], _ end: [String], _ value: [String]) -> Bool {
        let after = start.lexicographicallyPrecedes(value), before = value.lexicographicallyPrecedes(end)
        return start.lexicographicallyPrecedes(end) ? after && before : after || before
    }
    static func nsec3Covers(_ record: DNSSECWire.Record, name: String, zone: String) throws -> Bool {
        let labels = record.name.split(separator: ".")
        guard labels.dropFirst().joined(separator: ".") + "." == zone, let label = labels.first else { throw DNSSECError.malformed }
        let start = try base32hex(String(label))
        var reader = DNSSECWire.Reader(record.data)
        guard try reader.u8() == 1, try reader.u8() == 0 else { throw DNSSECError.unsupported }
        let iterations = try reader.u16(), saltLength = try reader.u8(), salt = try reader.take(Int(saltLength))
        let hashLength = try reader.u8(), next = try reader.take(Int(hashLength))
        guard iterations <= 250, saltLength <= 32, hashLength == 20, start.count == 20 else { throw DNSSECError.unsupported }
        var hash = Data(Insecure.SHA1.hash(data: try DNSSECWire.nameData(name) + salt))
        for _ in 0..<iterations { hash = Data(Insecure.SHA1.hash(data: hash + salt)) }
        return byteInterval(start, next, hash)
    }
    private static func byteInterval(_ start: Data, _ end: Data, _ value: Data) -> Bool {
        let after = start.lexicographicallyPrecedes(value), before = value.lexicographicallyPrecedes(end)
        return start.lexicographicallyPrecedes(end) ? after && before : after || before
    }
    private static func base32hex(_ value: String) throws -> Data {
        let alphabet = Array("0123456789abcdefghijklmnopqrstuv".utf8)
        let words = try value.lowercased().utf8.map { byte -> UInt8 in
            guard let index = alphabet.firstIndex(of: byte) else { throw DNSSECError.malformed }; return UInt8(index)
        }
        return Data(try SegwitAddress.convertBits(words, from: 5, to: 8, pad: false))
    }
}

