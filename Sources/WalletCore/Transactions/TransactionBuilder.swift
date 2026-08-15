import BitcoinCore
import BitcoinP2P
import Foundation

public enum TxBuildError: Error, Equatable {
    case noInputs
    case noOutputs
    case invalidAmount(Int64)
}

/// A payment target: an amount plus its destination scriptPubKey.
public struct Payment: Equatable, Sendable {
    public var amount: Int64
    public var scriptPubKey: Data

    public init(amount: Int64, scriptPubKey: Data) {
        self.amount = amount
        self.scriptPubKey = scriptPubKey
    }

    /// Pays any standard address type (bech32/bech32m segwit, base58 P2PKH/P2SH).
    public init(amount: Int64, address: String, network: BitcoinNetwork) throws {
        self.amount = amount
        scriptPubKey = try AddressDecoder.scriptPubKey(for: address, network: network)
    }
}

/// Transaction building on top of BitcoinP2P's wire model: version 2, segwit,
/// empty scriptSigs, BIP125-signaling sequences. Plus the exact vsize math for
/// P2TR key-path spends used by fee estimation and coin selection.
public enum TransactionBuilder {
    /// Sequence 0xFFFFFFFD: locktime-disabled, opt-in BIP125 replaceable.
    public static let defaultSequence: UInt32 = 0xFFFF_FFFD

    /// An unsigned transaction: payments first, the change output inserted at
    /// `changePosition` (a random position when nil, so change isn't always the
    /// last output — a chain-analysis fingerprint).
    public static func build(inputs: [Transaction.Outpoint], payments: [Payment],
                             change: Payment? = nil, changePosition: Int? = nil,
                             sequence: UInt32 = defaultSequence, locktime: UInt32 = 0) throws -> Transaction {
        guard !inputs.isEmpty else { throw TxBuildError.noInputs }
        var outputs = payments.map { Transaction.Output(value: $0.amount, scriptPubKey: $0.scriptPubKey) }
        if let change {
            let position = changePosition ?? Int.random(in: 0 ... outputs.count)
            precondition(position >= 0 && position <= outputs.count)
            outputs.insert(Transaction.Output(value: change.amount, scriptPubKey: change.scriptPubKey),
                           at: position)
        }
        guard !outputs.isEmpty else { throw TxBuildError.noOutputs }
        for output in outputs where output.value <= 0 { throw TxBuildError.invalidAmount(output.value) }
        let txInputs = inputs.map {
            Transaction.Input(previousOutput: $0, scriptSig: Data(), sequence: sequence)
        }
        return Transaction(version: 2, inputs: txInputs, outputs: outputs, locktime: locktime)
    }

    /// Exact vsize of the *signed* transaction assuming every input is a P2TR
    /// key-path spend: witness = one stack item of 64 bytes (SIGHASH_DEFAULT
    /// signature). weight = 3·base + total; vsize = ⌈weight / 4⌉ (BIP141).
    /// `witnessBytesPerInput` overrides the per-input witness byte count for
    /// other spend shapes (e.g. multi_a script-path vault inputs).
    public static func signedVSize(inputCount: Int, outputs: [Transaction.Output],
                                   witnessBytesPerInput: Int = 66) -> Int {
        let inputCountSize = compactSizeLength(UInt64(inputCount))
        let outputCountSize = compactSizeLength(UInt64(outputs.count))
        // Base (non-witness) bytes: version, locktime, varints, inputs, outputs.
        var base = 4 + 4 + inputCountSize + outputCountSize
        base += inputCount * (32 + 4 + 1 + 4) // outpoint, empty scriptSig length, sequence
        for output in outputs {
            base += 8 + compactSizeLength(UInt64(output.scriptPubKey.count)) + output.scriptPubKey.count
        }
        // Witness bytes: marker+flag, then per-input witness serialization.
        let witness = 2 + inputCount * witnessBytesPerInput
        return (3 * base + base + witness + 3) / 4
    }

    /// Exact vsize of a fully-signed transaction (witness included).
    public static func vsize(of tx: Transaction) -> Int {
        let base = tx.serialized(includeWitness: false).count
        let total = tx.serialized(includeWitness: true).count
        return (3 * base + total + 3) / 4
    }

    static func compactSizeLength(_ value: UInt64) -> Int {
        switch value {
        case ..<0xFD: 1
        case ...0xFFFF: 3
        case ...0xFFFF_FFFF: 5
        default: 9
        }
    }
}
