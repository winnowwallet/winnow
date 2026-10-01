import Foundation

/// BOLT 3 bounded shachain storage. Receiving a later secret must prove all
/// earlier secrets covered by its bucket. Invalid disclosures never mutate state.
public struct RevocationSecrets: Sendable, Codable {
    private struct Entry: Sendable, Codable { let index: UInt64; let secret: Data }
    private var buckets: [Int: Entry] = [:]
    public private(set) var received: UInt64 = 0
    public init() {}

    public mutating func insert(secret: Data, commitmentNumber: UInt64) throws {
        guard secret.count == 32, commitmentNumber == received,
              commitmentNumber <= ChannelKeys.maximumCommitmentNumber else { throw LightningError.invalidCommitment }
        let index = ChannelKeys.maximumCommitmentNumber - commitmentNumber
        let bucket = min(index.trailingZeroBitCount, 48)
        for prior in buckets.values where prior.index > index && canDerive(index, prior.index) {
            guard try derive(secret, from: index, to: prior.index) == prior.secret else {
                throw LightningError.invalidCommitment
            }
        }
        buckets[bucket] = Entry(index: index, secret: secret)
        received += 1
    }

    public func secret(for commitmentNumber: UInt64) throws -> Data {
        guard commitmentNumber < received else { throw LightningError.invalidCommitment }
        let index = ChannelKeys.maximumCommitmentNumber - commitmentNumber
        guard let entry = buckets.values.first(where: { canDerive($0.index, index) }) else {
            throw LightningError.invalidCommitment
        }
        return try derive(entry.secret, from: entry.index, to: index)
    }

    private func canDerive(_ from: UInt64, _ to: UInt64) -> Bool {
        let bits = min(from.trailingZeroBitCount, 48)
        return (from >> bits) == (to >> bits)
    }
    private func derive(_ value: Data, from: UInt64, to: UInt64) throws -> Data {
        guard value.count == 32, canDerive(from, to) else { throw LightningError.invalidCommitment }
        let bits = min(from.trailingZeroBitCount, 48)
        var secret = Array(value)
        for bit in stride(from: bits - 1, through: 0, by: -1) where to & (1 << bit) != 0 {
            secret[bit / 8] ^= UInt8(1 << (bit % 8))
            secret = Array(ChannelKeys.hash(Data(secret)))
        }
        return Data(secret)
    }
}
