import Foundation
import P256K
import WalletCore

/// BOLT12 uses Winnow's bit conversion, with the specified checksum-free
/// envelope. It is deliberately distinct from Bitcoin address decoding.
public enum Bolt12Encoding {
    static let alphabet = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l".utf8)
    public static func decode(_ string: String, prefix: String) throws -> Data {
        guard string.utf8.count <= 131_072 else { throw LightningError.invalidMessage }
        let joined = try join(string)
        guard joined == joined.lowercased() || joined == joined.uppercased() else { throw LightningError.invalidMessage }
        let lower = joined.lowercased(), marker = prefix + "1"
        guard lower.hasPrefix(marker) else { throw LightningError.invalidMessage }
        let symbols = try lower.utf8.dropFirst(marker.utf8.count).map { byte -> UInt8 in
            guard let index = alphabet.firstIndex(of: byte) else { throw LightningError.invalidMessage }
            return UInt8(index)
        }
        return Data(try SegwitAddress.convertBits(symbols, from: 5, to: 8, pad: false))
    }
    public static func encode(_ bytes: Data, prefix: String) throws -> String {
        guard ["lno", "lnr", "lni"].contains(prefix), bytes.count <= 65_535 else { throw LightningError.invalidMessage }
        let values = try SegwitAddress.convertBits(Array(bytes), from: 8, to: 5, pad: true)
        return prefix + "1" + String(decoding: values.map { alphabet[Int($0)] }, as: UTF8.self)
    }
    private static func join(_ string: String) throws -> String {
        let chunks = string.split(separator: "+", omittingEmptySubsequences: false)
        return try chunks.enumerated().map { index, chunk in
            let trimmed = index == 0 ? chunk : chunk.drop(while: { $0.isWhitespace })
            guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { throw LightningError.invalidMessage }
            return String(trimmed)
        }.joined()
    }
    public static func records(_ bytes: Data) throws -> [LightningWire.TLV] {
        guard !bytes.isEmpty, bytes.count <= 65_535 else { throw LightningError.invalidMessage }
        var reader = LightningWire.Reader(bytes), result: [LightningWire.TLV] = []
        while reader.remaining > 0 {
            let type = try reader.bigSize(), length = try reader.bigSize()
            guard result.last.map({ $0.type < type }) ?? true, length <= UInt64(reader.remaining) else { throw LightningError.invalidMessage }
            result.append(.init(type: type, value: try reader.take(Int(length))))
        }
        return result
    }
    public static func serialize(_ records: [LightningWire.TLV]) throws -> Data {
        var writer = LightningWire.Writer(); try writer.tlvs(records); return writer.data
    }
    public static func merkleRoot(_ bytes: Data) throws -> Data {
        let records = try records(bytes)
        let first = try serialize([records[0]])
        let nonceTag = Data("LnNonce".utf8) + first
        var leaves = try records.filter { !(240...1000).contains($0.type) }.map { record in
            var type = LightningWire.Writer(); type.bigSize(record.type)
            return try branch(tagged("LnLeaf", serialize([record])), tagged(nonceTag, type.data))
        }
        guard !leaves.isEmpty else { throw LightningError.invalidMessage }
        var offset = 1
        while offset < leaves.count {
            for index in stride(from: 0, to: leaves.count - offset, by: offset * 2) {
                leaves[index] = branch(leaves[index], leaves[index + offset])
            }
            offset *= 2
        }
        return leaves[0]
    }
    static func branch(_ first: Data, _ second: Data) -> Data {
        tagged("LnBranch", first.lexicographicallyPrecedes(second) ? first + second : second + first)
    }
    static func tagged(_ tag: String, _ data: Data) -> Data { tagged(Data(tag.utf8), data) }
    static func tagged(_ tag: Data, _ data: Data) -> Data {
        let hash = ChannelKeys.hash(tag); return ChannelKeys.hash(hash + hash + data)
    }
    public static func verify(_ bytes: Data, message: String, publicKey: Data) throws {
        _ = try ChannelKeys.point(publicKey)
        let records = try records(bytes)
        guard let value = records.first(where: { $0.type == 240 })?.value, value.count == 64 else { throw LightningError.invalidSignature }
        let signature = try P256K.Schnorr.SchnorrSignature(dataRepresentation: value)
        var digest = Array(try tagged("lightning" + message + "signature", merkleRoot(bytes)))
        guard P256K.Schnorr.XonlyKey(dataRepresentation: publicKey.suffix(32)).isValid(signature, for: &digest) else { throw LightningError.invalidSignature }
    }
    public static func sign(_ records: [LightningWire.TLV], message: String, secret: Data) throws -> Data {
        guard records.allSatisfy({ !(240...1000).contains($0.type) }) else { throw LightningError.invalidMessage }
        let bytes = try serialize(records)
        var digest = Array(try tagged("lightning" + message + "signature", merkleRoot(bytes)))
        var aux = Array(try P256K.Signing.PrivateKey().dataRepresentation)
        let key = try P256K.Schnorr.PrivateKey(dataRepresentation: secret)
        let signature = try key.signature(message: &digest, auxiliaryRand: &aux).dataRepresentation
        return try serialize((records + [.init(type: 240, value: signature)]).sorted { $0.type < $1.type })
    }
    static func integer(_ data: Data, maximumBytes: Int = 8) throws -> UInt64 {
        guard data.count <= maximumBytes, data.first != 0 else { throw LightningError.invalidMessage }
        return data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
    static func integer(_ value: UInt64) -> Data {
        var writer = LightningWire.Writer(); writer.u64(value)
        return Data(writer.data.drop(while: { $0 == 0 }))
    }
}
