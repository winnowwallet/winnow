import Foundation
import WalletCore

/// bLIP 50/51: channel quotes over the authenticated Lightning connection.
/// Winnow never pays a quote automatically.
public enum LightningLiquidity {
    public static let messageType: UInt16 = 37913
    public struct Info: Codable, Sendable {
        public let minRequiredChannelConfirmations: UInt16
        public let minFundingConfirmsWithinBlocks: UInt16
        public let maxChannelExpiryBlocks: UInt32
        public let minInitialClientBalanceSat, maxInitialClientBalanceSat: String
        public let minInitialLspBalanceSat, maxInitialLspBalanceSat: String
        public let minChannelBalanceSat, maxChannelBalanceSat: String
        public func request(capacitySat: UInt64, token: String = "") throws -> Purchase {
            guard let minimum = UInt64(minInitialLspBalanceSat), let maximum = UInt64(maxInitialLspBalanceSat),
                  let channelMin = UInt64(minChannelBalanceSat), let channelMax = UInt64(maxChannelBalanceSat),
                  capacitySat >= max(20_000, minimum, channelMin), capacitySat <= min(16_777_215, maximum, channelMax),
                  minInitialClientBalanceSat == "0", minFundingConfirmsWithinBlocks > 0,
                  minRequiredChannelConfirmations <= 144, maxChannelExpiryBlocks > 0 else { throw LightningError.invalidAmount }
            return Purchase(lspBalanceSat: String(capacitySat), clientBalanceSat: "0",
                requiredChannelConfirmations: max(3, minRequiredChannelConfirmations),
                fundingConfirmsWithinBlocks: minFundingConfirmsWithinBlocks,
                channelExpiryBlocks: min(13_140, maxChannelExpiryBlocks), token: token, announceChannel: false)
        }
        public var minimumCapacitySat: UInt64 {
            max(20_000, UInt64(minInitialLspBalanceSat) ?? .max, UInt64(minChannelBalanceSat) ?? .max)
        }
    }
    public struct Purchase: Codable, Sendable, Equatable {
        public let lspBalanceSat, clientBalanceSat: String
        public let requiredChannelConfirmations, fundingConfirmsWithinBlocks: UInt16
        public let channelExpiryBlocks: UInt32
        public let token: String
        public let announceChannel: Bool
    }
    public struct Order: Codable, Sendable {
        public struct Payment: Codable, Sendable {
            public struct Bolt11: Codable, Sendable {
                public let state, expiresAt, feeTotalSat, orderTotalSat, invoice: String
            }
            public let bolt11: Bolt11?
        }
        public let orderId, orderState, lspBalanceSat, clientBalanceSat: String
        public let requiredChannelConfirmations, fundingConfirmsWithinBlocks: UInt16
        public let channelExpiryBlocks: UInt32
        public let announceChannel: Bool
        public let payment: Payment
        public func validate(request: Purchase, network: BitcoinNetwork, now: UInt64) throws -> UInt64 {
            try validateBindings(request)
            let quoted = try validatedPayment()
            try validateInvoice(quoted.payment, fee: quoted.fee, network: network, now: now)
            return quoted.fee
        }
        private func validateBindings(_ request: Purchase) throws {
            guard !orderId.isEmpty, orderId.utf8.count <= 64, orderState == "CREATED",
                  lspBalanceSat == request.lspBalanceSat, clientBalanceSat == "0", !announceChannel,
                  requiredChannelConfirmations == request.requiredChannelConfirmations,
                  fundingConfirmsWithinBlocks == request.fundingConfirmsWithinBlocks,
                  channelExpiryBlocks == request.channelExpiryBlocks else { throw LightningError.invalidMessage }
        }
        private func validatedPayment() throws -> (payment: Payment.Bolt11, fee: UInt64) {
            guard let payment = payment.bolt11, payment.state == "EXPECT_PAYMENT",
                  let fee = UInt64(payment.feeTotalSat), fee > 0, fee <= 1_000_000,
                  payment.feeTotalSat == payment.orderTotalSat else { throw LightningError.invalidAmount }
            return (payment, fee)
        }
        private func validateInvoice(_ payment: Payment.Bolt11, fee: UInt64, network: BitcoinNetwork, now: UInt64) throws {
            let invoice = try Bolt11Invoice.decode(payment.invoice, network: network)
            guard invoice.amountMsat == fee * 1000, invoice.expiresAt > now,
                  let expires = LightningLiquidity.expiry(payment.expiresAt), expires > now else { throw LightningError.invalidMessage }
        }
    }
    public static func expiry(_ text: String) -> UInt64? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = parser.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        guard let date, date.timeIntervalSince1970 >= 0 else { return nil }
        return UInt64(date.timeIntervalSince1970)
    }
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }
    public static func decode<T: Decodable>(_ type: T.Type, from bytes: Data) throws -> T {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: bytes)
    }
    static func message(method: String, params: Data, id: String) throws -> LightningWire.Message {
        guard params.count <= 8192, let object = try JSONSerialization.jsonObject(with: params) as? [String: Any] else { throw LightningError.invalidMessage }
        let bytes = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": object], options: .sortedKeys)
        return try .init(type: messageType, payload: bytes)
    }
    /// bLIP-50: a response we cannot match (no string id, a notification, a
    /// malformed payload) is ignored, never fatal to the connection.
    static func response(_ message: LightningWire.Message) -> (id: String, result: Result<Data, LightningLiquidityError>)? {
        guard message.type == messageType, message.payload.count <= 32_768,
              let object = (try? JSONSerialization.jsonObject(with: message.payload)) as? [String: Any],
              object["jsonrpc"] as? String == "2.0", let id = object["id"] as? String else { return nil }
        switch (object["error"] as? [String: Any], object["result"] as? [String: Any]) {
        case (let error?, nil): return (id, .failure(rejection(error)))
        case (nil, let result?):
            guard let bytes = try? JSONSerialization.data(withJSONObject: result) else { return nil }
            return (id, .success(bytes))
        default: return nil
        }
    }
    private static func rejection(_ error: [String: Any]) -> LightningLiquidityError {
        let reason = String((error["message"] as? String ?? "Request refused").prefix(200))
        guard let code = error["code"] as? Int else { return .provider(reason) }
        return .rejected(code: code, message: reason)
    }
}

public enum LightningLiquidityError: Error, LocalizedError, Sendable, Equatable {
    case unavailable, timedOut, provider(String), rejected(code: Int, message: String)
    public var errorDescription: String? {
        switch self {
        case .unavailable: "This provider does not support channel purchases over this connection."
        case .timedOut: "The provider did not respond. Reconnect and try again; no setup fee was paid by Winnow."
        case .provider(let reason): "Provider: \(reason)"
        case .rejected(let code, let message): Self.explain(code) ?? "Provider: \(message)"
        }
    }
    /// bLIP-52 error codes, in words a person can act on.
    private static func explain(_ code: Int) -> String? {
        switch code {
        case 1: "The provider refused this request."
        case 200: "The provider did not accept Winnow's access token."
        case 201: "The provider's fee terms changed. Get a new quote."
        case 202: "This amount is below the provider's minimum."
        case 203: "This amount is above the provider's maximum."
        default: nil
        }
    }
}
