import Foundation

/// bLIP-52 (LSPS2): a just-in-time channel bought for one payment. The
/// provider opens a private channel when the payment arrives and keeps its
/// opening fee out of that payment.
public enum LightningJIT {
    /// The least a just-in-time channel must deliver after the fee. Winnow
    /// accepts no channel smaller than 20,000 sats, and the provider opens one
    /// at least as large as the payment it forwards.
    public static let minimumDelivered: UInt64 = 20_000_000

    /// One `opening_fee_params` entry, as the provider wrote it.
    public struct FeeParams: Codable, Sendable, Equatable {
        public let minFeeMsat: String
        public let proportional: UInt32
        public let validUntil: String
        public let minLifetime: UInt32
        public let maxClientToSelfDelay: UInt32
        public let minPaymentSizeMsat: String?
        public let maxPaymentSizeMsat: String?
        public let promise: String
    }

    /// A menu entry Winnow can buy. `raw` is the provider's object verbatim:
    /// lsps2.buy must return it unchanged so its promise still verifies.
    public struct Offer: Sendable, Equatable {
        public let params: FeeParams
        public let raw: Data
        public let validUntil: UInt64
        public let minFeeMsat, minPaymentMsat, maxPaymentMsat: UInt64

        init(raw: Data, defaultBounds: (min: UInt64?, max: UInt64?), now: UInt64) throws {
            let params = try LightningLiquidity.decode(FeeParams.self, from: raw)
            guard let validUntil = LightningLiquidity.expiry(params.validUntil), validUntil > now,
                  let minFee = UInt64(params.minFeeMsat), Offer.acceptable(promise: params.promise),
                  params.maxClientToSelfDelay >= 144 else { throw LightningError.invalidMessage }
            let minimum = try Offer.bound(params.minPaymentSizeMsat, fallback: defaultBounds.min)
            let maximum = try Offer.bound(params.maxPaymentSizeMsat, fallback: defaultBounds.max)
            guard minimum <= maximum else { throw LightningError.invalidMessage }
            self.params = params; self.raw = raw; self.validUntil = validUntil
            minFeeMsat = minFee; minPaymentMsat = minimum; maxPaymentMsat = maximum
        }
        private static func bound(_ text: String?, fallback: UInt64?) throws -> UInt64 {
            guard let value = text.map({ UInt64($0) }) ?? fallback else { throw LightningError.invalidMessage }
            return value
        }
        static func acceptable(promise: String) -> Bool {
            promise.utf8.count <= 512 && promise.unicodeScalars.allSatisfy { (0x20...0x7e).contains($0.value) }
        }
        /// The smallest payment this entry accepts once its fee is taken. What
        /// a payment delivers never shrinks as the payment grows.
        public var smallestPaymentMsat: UInt64? {
            guard (try? fee(paymentMsat: maxPaymentMsat)) != nil else { return nil }
            var low = minPaymentMsat, high = maxPaymentMsat
            while low < high {
                let middle = low + (high - low) / 2
                if (try? fee(paymentMsat: middle)) != nil { high = middle } else { low = middle + 1 }
            }
            return low
        }
        /// The fee the provider keeps from a payment of this size. The fee
        /// must leave the payment something to deliver.
        public func fee(paymentMsat: UInt64) throws -> UInt64 {
            guard (minPaymentMsat...maxPaymentMsat).contains(paymentMsat),
                  let fee = LightningJIT.openingFee(paymentMsat: paymentMsat, minFeeMsat: minFeeMsat,
                                                    proportional: params.proportional),
                  fee < paymentMsat, paymentMsat - fee >= LightningJIT.minimumDelivered else { throw LightningError.invalidAmount }
            return fee
        }
    }

    public struct Menu: Sendable {
        public let offers: [Offer]

        /// Entries that fail validation or have already expired are left out.
        public static func decode(_ data: Data, now: UInt64) throws -> Menu {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let entries = object["opening_fee_params_menu"] as? [[String: Any]] else { throw LightningError.invalidMessage }
            // Earlier LSPS2 drafts put the payment bounds beside the menu.
            let bounds = (min: (object["min_payment_size_msat"] as? String).flatMap(UInt64.init),
                          max: (object["max_payment_size_msat"] as? String).flatMap(UInt64.init))
            let offers = entries.compactMap { entry in
                (try? JSONSerialization.data(withJSONObject: entry)).flatMap { try? Offer(raw: $0, defaultBounds: bounds, now: now) }
            }
            return Menu(offers: offers)
        }
        /// The cheapest entry that accepts this payment and stays valid long
        /// enough for an invoice to be paid.
        public func cheapest(paymentMsat: UInt64, now: UInt64) throws -> (offer: Offer, feeMsat: UInt64) {
            let quotes = offers.filter { $0.validUntil >= now + 90 }
                .compactMap { offer in (try? offer.fee(paymentMsat: paymentMsat)).map { (offer, $0) } }
            guard let best = quotes.min(by: { $0.1 < $1.1 }) else { throw LightningError.invalidAmount }
            return best
        }
        /// The smallest payment any entry still valid for an invoice accepts.
        public func smallestPaymentMsat(now: UInt64) -> UInt64? {
            offers.filter { $0.validUntil >= now + 90 }.compactMap(\.smallestPaymentMsat).min()
        }
        /// The payment sizes some current entry accepts.
        public var paymentRange: ClosedRange<UInt64>? {
            guard let low = offers.map(\.minPaymentMsat).min(), let high = offers.map(\.maxPaymentMsat).max() else { return nil }
            return low...high
        }
    }

    /// lsps2.buy's answer: the scid the provider intercepts, for the invoice's
    /// route hint.
    public struct Purchase: Codable, Sendable, Equatable {
        public let jitChannelScid: String
        public let lspCltvExpiryDelta: UInt32
        public let clientTrustsLsp: Bool?

        public func validated() throws -> (scid: UInt64, delta: UInt16) {
            guard let scid = LightningJIT.scid(jitChannelScid), (1...2016).contains(lspCltvExpiryDelta) else {
                throw LightningError.invalidMessage
            }
            return (scid, UInt16(lspCltvExpiryDelta))
        }
    }

    /// bLIP-52: ceil(payment * proportional / 1e6), at least min_fee_msat,
    /// with every step checked for overflow.
    public static func openingFee(paymentMsat: UInt64, minFeeMsat: UInt64, proportional: UInt32) -> UInt64? {
        let (product, multiplied) = paymentMsat.multipliedReportingOverflow(by: UInt64(proportional))
        let (rounded, added) = product.addingReportingOverflow(999_999)
        guard !multiplied, !added else { return nil }
        return max(rounded / 1_000_000, minFeeMsat)
    }

    /// LSPS0 short channel ids are written `BLOCKxTXxOUTPUT`.
    static func scid(_ text: String) -> UInt64? {
        let parts = text.split(separator: "x", omittingEmptySubsequences: false).map { UInt64($0) }
        guard parts.count == 3, let block = parts[0], let tx = parts[1], let output = parts[2],
              block < 1 << 24, tx < 1 << 24, output < 1 << 16 else { return nil }
        let scid = block << 40 | tx << 16 | output
        return scid == 0 ? nil : scid
    }

    static func buyParams(_ offer: Offer, paymentSizeMsat: UInt64) throws -> Data {
        let params = try JSONSerialization.jsonObject(with: offer.raw)
        return try JSONSerialization.data(withJSONObject: ["opening_fee_params": params,
                                                           "payment_size_msat": String(paymentSizeMsat)], options: .sortedKeys)
    }
}
