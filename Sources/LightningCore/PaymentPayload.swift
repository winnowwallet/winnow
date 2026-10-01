import Foundation

/// A final, single-part BOLT 4 TLV payload. A reusable offer or invoice may be
/// parsed successfully while its payment secret, amount or expiry is invalid;
/// settlement must validate all of them against the persisted receive request.
public struct PaymentPayload: Sendable, Equatable {
    public let amountMsat: UInt64, totalMsat: UInt64
    public let expiry: UInt32
    public let secret: Data
    public init(amountMsat: UInt64, expiry: UInt32, secret: Data) throws {
        guard amountMsat > 0, secret.count == 32, expiry > 0 else { throw LightningError.invalidMessage }
        self.amountMsat = amountMsat; totalMsat = amountMsat; self.expiry = expiry; self.secret = secret
    }
    public init(bytes: Data) throws {
        var reader = LightningWire.Reader(bytes)
        let tlvs = try reader.tlvs(known: [2, 4, 8, 16])
        guard let amount = tlvs.first(where: { $0.type == 2 }), let cltv = tlvs.first(where: { $0.type == 4 }),
              let payment = tlvs.first(where: { $0.type == 8 }), (32...40).contains(payment.value.count)
        else { throw LightningError.invalidMessage }
        amountMsat = try Self.integer(amount.value, maximumBytes: 8)
        expiry = try UInt32(Self.integer(cltv.value, maximumBytes: 4))
        secret = Data(payment.value.prefix(32))
        totalMsat = try Self.integer(Data(payment.value.dropFirst(32)), maximumBytes: 8)
        guard amountMsat > 0, totalMsat == amountMsat, expiry > 0 else { throw LightningError.invalidAmount }
    }
    public var bytes: Data {
        var writer = LightningWire.Writer()
        for (type, bytes): (UInt64, Data) in [(2, Self.truncated(amountMsat)), (4, Self.truncated(UInt64(expiry))), (8, secret + Self.truncated(totalMsat))] {
            writer.bigSize(type); writer.bigSize(UInt64(bytes.count)); writer.append(bytes)
        }
        return writer.data
    }
    public func validate(expectedSecret: Data, expectedAmount: UInt64, receivedAmount: UInt64,
                         receivedExpiry: UInt32, height: UInt32, minimumDelta: UInt32) throws {
        guard secret == expectedSecret, amountMsat == expectedAmount, totalMsat == expectedAmount,
              receivedAmount >= amountMsat, receivedExpiry >= expiry,
              UInt64(receivedExpiry) >= UInt64(height) + UInt64(minimumDelta) else { throw LightningError.invalidMessage }
    }
    static func truncated(_ integer: UInt64) -> Data {
        var writer = LightningWire.Writer(); writer.u64(integer)
        return Data(writer.data.drop(while: { $0 == 0 }))
    }
    private static func integer(_ bytes: Data, maximumBytes: Int) throws -> UInt64 {
        guard bytes.count <= maximumBytes, bytes.first != 0 else { throw LightningError.invalidMessage }
        return bytes.reduce(0) { ($0 << 8) | UInt64($1) }
    }
}
