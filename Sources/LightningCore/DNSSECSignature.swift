import CryptoKit
import Foundation
import Security

enum DNSSECSignature {
    struct Key {
        let bytes: Data, flags: UInt16, algorithm: UInt8, tag: UInt16, material: Data
        init(_ data: Data) throws {
            var reader = DNSSECWire.Reader(data)
            flags = try reader.u16()
            guard try reader.u8() == 3, flags & 0x100 != 0, flags & 0x80 == 0 else { throw DNSSECError.unauthenticated }
            algorithm = try reader.u8(); material = try reader.take(reader.bytes.count - reader.offset); bytes = data
            var sum = data.enumerated().reduce(UInt32(0)) { $0 + ($1.offset % 2 == 0 ? UInt32($1.element) << 8 : UInt32($1.element)) }
            sum += (sum >> 16) & 0xffff; tag = UInt16(sum & 0xffff)
        }
    }
    struct Signature {
        let covered: UInt16, algorithm: UInt8, labels: UInt8, originalTTL: UInt32
        let expiration: UInt32, inception: UInt32, tag: UInt16, signer: String, signature: Data, header: Data
        init(_ bytes: Data) throws {
            var reader = DNSSECWire.Reader(bytes)
            covered = try reader.u16(); algorithm = try reader.u8(); labels = try reader.u8(); originalTTL = try reader.u32()
            expiration = try reader.u32(); inception = try reader.u32(); tag = try reader.u16(); signer = try reader.name()
            header = Data(bytes.prefix(reader.offset)); signature = try reader.take(reader.bytes.count - reader.offset)
        }
    }
    static func verify(_ signature: Signature, key: Key, records: [DNSSECWire.Record], now: UInt64) throws -> UInt64 {
        guard signature.algorithm == key.algorithm, signature.tag == key.tag,
              now >= UInt64(signature.inception), now <= UInt64(signature.expiration), let first = records.first else { throw DNSSECError.expired }
        let labels = first.name.split(separator: ".")
        guard Int(signature.labels) <= labels.count else { throw DNSSECError.malformed }
        let signedOwner = Int(signature.labels) == labels.count ? first.name : "*." + labels.suffix(Int(signature.labels)).joined(separator: ".") + "."
        let owner = try DNSSECWire.nameData(signedOwner)
        let canonical = try records.sorted { $0.data.lexicographicallyPrecedes($1.data) }.map { record -> Data in
            guard record.name == first.name, record.type == signature.covered, record.dnsClass == 1 else { throw DNSSECError.malformed }
            var writer = LightningWire.Writer(); writer.append(owner); writer.u16(record.type); writer.u16(1)
            writer.u32(signature.originalTTL); writer.u16(UInt16(record.data.count)); writer.append(record.data); return writer.data
        }
        let message = signature.header + canonical.reduce(Data(), +)
        guard try valid(signature.signature, message: message, key: key) else { throw DNSSECError.unauthenticated }
        return min(UInt64(signature.originalTTL), UInt64(signature.expiration) - now, UInt64(records.map(\.ttl).min() ?? 0))
    }
    static func matchesDS(_ bytes: Data, key: Key, zone: String) throws -> Bool {
        var reader = DNSSECWire.Reader(bytes)
        let tag = try reader.u16(), algorithm = try reader.u8(), digestType = try reader.u8(), digest = try reader.take(reader.bytes.count - reader.offset)
        guard tag == key.tag, algorithm == key.algorithm else { return false }
        let material = try DNSSECWire.nameData(zone) + key.bytes
        switch digestType {
        case 2: return digest == Data(SHA256.hash(data: material))
        case 4: return digest == Data(SHA384.hash(data: material))
        default: return false
        }
    }
    private static func valid(_ signature: Data, message: Data, key: Key) throws -> Bool {
        switch key.algorithm {
        case 8, 10: return try rsa(signature, message: message, key: key)
        case 13:
            return try P256.Signing.PublicKey(x963Representation: Data([4]) + key.material)
                .isValidSignature(P256.Signing.ECDSASignature(rawRepresentation: signature), for: message)
        case 14:
            return try P384.Signing.PublicKey(x963Representation: Data([4]) + key.material)
                .isValidSignature(P384.Signing.ECDSASignature(rawRepresentation: signature), for: message)
        case 15: return try Curve25519.Signing.PublicKey(rawRepresentation: key.material).isValidSignature(signature, for: message)
        default: throw DNSSECError.unsupported // SHA-1 signatures are never accepted.
        }
    }
    private static func rsa(_ signature: Data, message: Data, key: Key) throws -> Bool {
        var reader = DNSSECWire.Reader(key.material)
        let short = try reader.u8(), length = try short == 0 ? Int(reader.u16()) : Int(short)
        let exponent = try reader.take(length), modulus = try reader.take(reader.bytes.count - reader.offset)
        let bits = modulus.first.map { (modulus.count - 1) * 8 + 8 - $0.leadingZeroBitCount } ?? 0
        guard bits >= 1024, modulus.count <= 512, length > 0, length <= 8 else { throw DNSSECError.unsupported }
        let der = element(0x30, integer(modulus) + integer(exponent))
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic, kSecAttrKeySizeInBits as String: modulus.count * 8]
        guard let publicKey = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil) else { throw DNSSECError.malformed }
        let algorithm: SecKeyAlgorithm = key.algorithm == 8 ? .rsaSignatureMessagePKCS1v15SHA256 : .rsaSignatureMessagePKCS1v15SHA512
        return SecKeyVerifySignature(publicKey, algorithm, message as CFData, signature as CFData, nil)
    }
    private static func integer(_ bytes: Data) -> Data {
        let value = Data(bytes.drop(while: { $0 == 0 }))
        return element(2, value.first.map({ $0 & 0x80 != 0 }) == true ? Data([0]) + value : value)
    }
    private static func element(_ tag: UInt8, _ value: Data) -> Data {
        let length: Data
        if value.count < 128 { length = Data([UInt8(value.count)]) }
        else if value.count <= 255 { length = Data([0x81, UInt8(value.count)]) }
        else { length = Data([0x82, UInt8(value.count >> 8), UInt8(value.count & 255)]) }
        return Data([tag]) + length + value
    }
}
