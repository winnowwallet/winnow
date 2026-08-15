import BitcoinP2P
import Foundation

public enum CoinSelectionError: Error, Equatable {
    case noUTXOs
    case insufficientFunds(available: Int64, required: Int64)
    /// Feerate was non-positive, non-finite, or above the absurd-fee ceiling.
    case invalidFeeRate(Double)
    /// A payment output is below the dust relay threshold and would not relay.
    case dustOutput(value: Int64, threshold: Int64)
}

/// The outcome of a coin selection: which UTXOs to spend, the fee at the
/// requested feerate, and the change amount (nil = no change output — the
/// remainder folded into the fee).
public struct Selection: Equatable, Sendable {
    public var selected: [WalletUTXO]
    public var fee: Int64
    public var changeAmount: Int64?

    public init(selected: [WalletUTXO], fee: Int64, changeAmount: Int64?) {
        self.selected = selected
        self.fee = fee
        self.changeAmount = changeAmount
    }
}

/// Largest-first coin selection with a dust guard (Bitcoin Core dust policy,
/// policy.cpp GetDustThreshold) and exact fee estimation for P2TR key-path
/// spends.
public enum CoinSelection {
    /// Default minimum relay feerate for dust purposes (3000 sat/kvB, Core's
    /// default dustRelayFee).
    public static let defaultDustRelayFeeSatPerKvB: Int64 = 3_000

    /// Core's dust rule: an output is dust when spending it costs more than
    /// its value at the dust relay feerate. For witness programs Core adds a
    /// fixed 67 bytes for the discounted input (32+4+1+107/4+4), so a 43-byte
    /// P2TR txout is dust below 110 × 3 = **330 sats** at the default rate.
    /// (The often-quoted 294 sats is the *P2WPKH* threshold — 31+67 bytes.)
    public static func dustThreshold(scriptPubKey: Data,
                                     relayFeeSatPerKvB: Int64 = defaultDustRelayFeeSatPerKvB) -> Int64 {
        let outputSize = 8 + TransactionBuilder.compactSizeLength(UInt64(scriptPubKey.count)) + scriptPubKey.count
        // Witness program: OP_0 or OP_1..OP_16 followed by a 2–40 byte push.
        let version = scriptPubKey.first ?? 0xFF
        let isWitness = scriptPubKey.count >= 4
            && (version == 0x00 || (version >= 0x51 && version <= 0x60))
            && scriptPubKey.count == 2 + Int(scriptPubKey[scriptPubKey.index(scriptPubKey.startIndex, offsetBy: 1)])
            && scriptPubKey.count >= 4 && scriptPubKey.count <= 42
        let spendSize = isWitness ? 32 + 4 + 1 + 107 / 4 + 4 : 32 + 4 + 1 + 107 + 4
        return Int64(outputSize + spendSize) * relayFeeSatPerKvB / 1_000
    }

    /// Largest-first: accumulate the biggest UTXOs until the selection covers
    /// the payment total plus the fee for the transaction as built so far
    /// (each added input grows the fee — the loop accounts for it). A change
    /// output is added when the remainder clears its dust threshold; dust
    /// remainders fold into the fee instead of creating an unspendable output.
    /// `witnessBytesPerInput` overrides the per-input witness size used for
    /// fee estimation (default: the 66 bytes of a P2TR key-path spend).
    public static func select(utxos: [WalletUTXO], payments: [Payment],
                              changeScriptPubKey: Data, feeRateSatPerVByte: Double,
                              witnessBytesPerInput: Int = 66) throws -> Selection {
        guard !utxos.isEmpty else { throw CoinSelectionError.noUTXOs }
        // A negative/zero/NaN feerate underflows the fee (inflating change past
        // the inputs into an invalid tx); an absurd one silently burns the
        // balance. Core's sendrawtransaction ceiling is 0.10 BTC/kvB = 10 000
        // sat/vB — reject anything outside (0, 10 000].
        guard feeRateSatPerVByte.isFinite, feeRateSatPerVByte > 0,
              feeRateSatPerVByte <= 10_000 else {
            throw CoinSelectionError.invalidFeeRate(feeRateSatPerVByte)
        }
        // Payment outputs must clear their own dust threshold — the change
        // output is guarded below, but a sub-dust payment builds a tx no peer
        // will relay, stranding the (locally committed) inputs.
        for payment in payments {
            let threshold = dustThreshold(scriptPubKey: payment.scriptPubKey)
            guard payment.amount >= threshold else {
                throw CoinSelectionError.dustOutput(value: payment.amount, threshold: threshold)
            }
        }
        let target = payments.reduce(Int64(0)) { $0 + $1.amount }
        let paymentOutputs = payments.map {
            Transaction.Output(value: $0.amount, scriptPubKey: $0.scriptPubKey)
        }
        let changeOutput = Transaction.Output(value: 0, scriptPubKey: changeScriptPubKey)

        func fee(inputCount: Int, withChange: Bool) -> Int64 {
            let outputs = withChange ? paymentOutputs + [changeOutput] : paymentOutputs
            let vsize = TransactionBuilder.signedVSize(inputCount: inputCount, outputs: outputs,
                                                       witnessBytesPerInput: witnessBytesPerInput)
            return Int64((Double(vsize) * feeRateSatPerVByte).rounded(.up))
        }

        var selected: [WalletUTXO] = []
        var total: Int64 = 0
        for utxo in utxos.sorted(by: { $0.amount > $1.amount }) {
            selected.append(utxo)
            total += utxo.amount
            // Try with a change output first — that's the shape the tx will have.
            if total >= target + fee(inputCount: selected.count, withChange: true) { break }
        }

        let feeWithChange = fee(inputCount: selected.count, withChange: true)
        guard total >= target + fee(inputCount: selected.count, withChange: false) else {
            throw CoinSelectionError.insufficientFunds(available: total,
                                                       required: target + fee(inputCount: selected.count, withChange: false))
        }

        let change = total - target - feeWithChange
        if change >= dustThreshold(scriptPubKey: changeScriptPubKey) {
            return Selection(selected: selected, fee: feeWithChange, changeAmount: change)
        }
        // Change is dust (or exactly zero): no change output; the remainder
        // becomes fee. The fee must still cover the smaller changeless tx.
        let finalFee = total - target
        return Selection(selected: selected, fee: finalFee, changeAmount: nil)
    }
}
