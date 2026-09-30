import Foundation
import LightningCore
import WalletCore

extension Fixture {
    /// Added test-wallet input/change preserves the peer's production 0x83
    /// signatures and delayed HTLC output. Core signs only its additional coin.
    static func augmentHTLC(_ arguments: [String]) throws -> [String: String] {
        guard arguments.count == 7, let raw = Data(hex: arguments[1]), let txid = Data(hex: arguments[2]),
              let vout = UInt32(arguments[3]), let amount = Int64(arguments[4]), let destination = Data(hex: arguments[5]),
              let fee = Int64(arguments[6]), amount > fee else { throw LightningError.invalidMessage }
        var tx = try Transaction.decode(raw)
        guard tx.inputs.count == 1, tx.outputs.count == 1, tx.inputs[0].witness.count == 5,
              tx.inputs[0].witness[1].last == 0x83, tx.inputs[0].witness[2].last == 0x83 else { throw LightningError.invalidCommitment }
        tx.inputs.append(.init(previousOutput: .init(txid: Data(txid.reversed()), vout: vout), scriptSig: Data(), sequence: 0xfffffffd))
        tx.outputs.append(.init(value: amount - fee, scriptPubKey: destination))
        return ["transaction": tx.serialized(includeWitness: true).hex]
    }
}
