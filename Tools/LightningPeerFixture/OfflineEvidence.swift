import CryptoKit
import Foundation
import LightningCore
import WalletCore

extension PeerFixture {
    /// Fixture-only read-only classification of a durably queued ciphertext.
    /// No engine, journal, network connection or release response is created.
    static func inspectHeld(_ args: [String]) throws {
        guard args.count == 3, let raw = Data(hex: args[2]) else {
            throw LightningError.invalidMessage
        }
        let secret = UInt8(args[1]).map { Data(repeating: $0, count: 32) } ?? Data(hex: args[1]) ?? Data()
        guard secret.count == 32 else { throw LightningError.invalidKey }
        let key = Data(HMAC<CryptoKit.SHA256>.authenticationCode(for: secret,
            using: SymmetricKey(data: Data("winnow_async_context_v1".utf8))))
        var held = false
        if case .receive(let content, let context, let reply) = try? OnionMessage.peel(
            .init(type: 513, payload: raw), nodeSecret: secret, authenticationKey: key),
           context.count == 33, context.first == 3, reply != nil,
           case .held = try? AsyncPaymentMessage(record: content) { held = true }
        try emit(["held": held ? "true" : "false"])
    }
}
