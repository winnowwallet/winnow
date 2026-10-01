import Foundation
import WalletCore

public enum LightningInvoiceError: LocalizedError {
    case expired, unsupported, noRoute, unavailable, changed
    public var errorDescription: String? {
        switch self {
        case .expired: "This Lightning invoice has expired. Request a new invoice."
        case .unsupported: "This invoice requires a payment feature Winnow does not support."
        case .noRoute: "No usable route was found within the amount, fee and expiry limits."
        case .unavailable: "Connect and sync a funded Lightning channel before paying."
        case .changed: "The payment changed. Review it again before paying."
        }
    }
}

extension Bolt11Invoice {
    public static func normalized(_ text: String) -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.lowercased().hasPrefix("lightning:") ? String(value.dropFirst(10)) : value
    }
    public static func millisatoshis(_ sats: String) throws -> UInt64 {
        let parts = sats.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), !parts[0].isEmpty,
              parts.allSatisfy({ $0.utf8.allSatisfy { (48...57).contains($0) } }),
              parts.count == 1 || (1...3).contains(parts[1].count), let whole = UInt64(parts[0]), whole <= 16_777_215
        else { throw LightningError.invalidAmount }
        let fraction = parts.count == 1 ? 0 : UInt64(parts[1] + String(repeating: "0", count: 3 - parts[1].count))!
        let value = whole * 1000 + fraction
        guard value > 0, value <= 16_777_215_000 else { throw LightningError.invalidAmount }
        return value
    }
    public static func sats(_ msat: UInt64) -> String {
        let remainder = msat % 1000
        return remainder == 0 ? String(msat / 1000) : "\(msat / 1000)." + String(format: "%03llu", remainder).replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
    }
    public static func paymentFeatures(_ words: [UInt8]) throws -> LightningFeatures {
        var bits = Set<Int>()
        for (index, word) in words.reversed().enumerated() {
            for bit in 0..<5 where word & (1 << bit) != 0 { bits.insert(index * 5 + bit) }
        }
        return try LightningFeatures(bits: bits)
    }
}

extension Bolt11Invoice.Decoded {
    public func validatePayment(amountMsat: UInt64, now: UInt64) throws {
        guard now < expiresAt else { throw LightningInvoiceError.expired }
        guard amountMsat > 0, amountMsat <= 16_777_215_000,
              self.amountMsat == nil || self.amountMsat == amountMsat else { throw LightningError.invalidAmount }
        do { try features.validateRequired(supported: [8, 14, 16, 48]) }
        catch { throw LightningInvoiceError.unsupported }
        guard paymentSecret?.count == 32,
              !features.supports(16) || features.supports(14), !features.supports(14) || features.supports(8),
              !features.supports(48) || metadata != nil else { throw LightningInvoiceError.unsupported }
    }
}
