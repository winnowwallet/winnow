import Foundation
import WalletCore

/// A reviewable, bounded CPFP child or anchor-HTLC replacement. Input zero and
/// (for HTLCs) output zero are the channel's; every added input belongs to Winnow.
/// The wallet must reserve `selected` durably before signing inputs 1 onward.
public struct AnchorFeeBump: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable { case commitment, htlc }
    public let id: Data
    public let channelID: Data
    public let kind: Kind
    public let parentTransaction: Data
    public let unsignedTransaction: Data
    public let selected: [WalletUTXO]
    public let feeSat: UInt64
    public let parentFeeSat: UInt64
    public let totalFeeLimitSat: UInt64
    public let replacesTxid: Data?
    public internal(set) var signedTransaction: Data?

    public var packageFeeSat: UInt64 { feeSat + parentFeeSat }
    public func transaction() throws -> Transaction { try Transaction.decode(signedTransaction ?? unsignedTransaction) }
    public func spentOutputs() throws -> [SighashBIP341.SpentOutput] {
        let tx = try Transaction.decode(unsignedTransaction)
        let parent = try Transaction.decode(parentTransaction)
        guard let input = tx.inputs.first, parent.outputs.indices.contains(Int(input.previousOutput.vout)),
              input.previousOutput.txid == parent.txid else { throw LightningError.invalidCommitment }
        let output = parent.outputs[Int(input.previousOutput.vout)]
        return [.init(amount: output.value, scriptPubKey: output.scriptPubKey)] + selected.map(\.spentOutput)
    }
}

/// Reuses Winnow's coin selection, dust policy, transaction model and signatures.
/// Package fees count the parent's fee as well as the child, under one total cap.
enum AnchorFeeBumpBuilder {
    struct Target {
        let parent: Transaction
        let transaction: Transaction
        let parentFee: UInt64
        let kind: AnchorFeeBump.Kind
        let anchorScript: Script?
    }
    static func quote(id: Data, channelID: Data, target: Target, coins: [WalletUTXO], destination: Data,
                      rate: Double, limit: UInt64, replacing: AnchorFeeBump?) throws -> AnchorFeeBump {
        try validateRequest(id: id, destination: destination, rate: rate, limit: limit, target: target)
        try validateReplacementTarget(target, replacing: replacing)
        let selected = try selection(target: target, coins: coins, destination: destination, rate: rate, replacing: replacing)
        var tx = target.transaction
        tx.inputs += selected.map { .init(previousOutput: $0.outpoint, scriptSig: Data(), sequence: 0xfffffffd) }
        let template = Transaction.Output(value: 0, scriptPubKey: destination)
        tx.outputs.append(template)
        let fee = try requiredFee(tx: tx, target: target, rate: rate, replacing: replacing)
        try validateLimit(fee: fee, parentFee: target.parentFee, limit: limit, replacing: replacing)
        let total = selected.reduce(Int64(0)) { $0 + $1.amount } + (target.kind == .commitment ? 330 : 0)
        let change = total - Int64(fee)
        guard change >= CoinSelection.dustThreshold(scriptPubKey: destination) else { throw LightningError.invalidAmount }
        tx.outputs[tx.outputs.count - 1].value = change
        return AnchorFeeBump(id: id, channelID: channelID, kind: target.kind,
            parentTransaction: target.parent.serialized(includeWitness: true), unsignedTransaction: tx.serialized(includeWitness: true),
            selected: selected, feeSat: fee, parentFeeSat: target.parentFee, totalFeeLimitSat: limit,
            replacesTxid: try replacing?.transaction().txid)
    }
    private static func selection(target: Target, coins: [WalletUTXO], destination: Data,
                                  rate: Double, replacing: AnchorFeeBump?) throws -> [WalletUTXO] {
        if let replacing {
            guard replacing.selected.allSatisfy({ coins.contains($0) }) else { throw LightningError.invalidState }
            return replacing.selected
        }
        // Selection deliberately overestimates the parent's cost and channel
        // input witness. The returned transaction pays the exact bounded quote.
        let parentSize = target.kind == .commitment ? vsize(target.parent) : 0
        let baseSize = TransactionBuilder.signedVSize(inputCount: 1, outputs: [.init(value: 330, scriptPubKey: destination)])
        let selectionRate = min(10_000, rate * Double(parentSize + baseSize + 250) / Double(baseSize))
        let selection = try CoinSelection.select(utxos: coins, payments: [.init(amount: 330, scriptPubKey: destination)],
            changeScriptPubKey: destination, feeRateSatPerVByte: selectionRate)
        guard selection.selected.count <= 64, selection.selected.allSatisfy({ !$0.isSpent && $0.height > 0 }),
              selection.selected.allSatisfy({ $0.scriptPubKey.count == 34 && $0.scriptPubKey.prefix(2) == Data([0x51, 32]) })
        else { throw LightningError.invalidAmount }
        return selection.selected
    }
    static func validateReplacementTarget(_ target: Target, replacing: AnchorFeeBump?) throws {
        guard let replacing else { return }
        let original = try Transaction.decode(replacing.unsignedTransaction)
        guard replacing.kind == target.kind,
              replacing.parentTransaction == target.parent.serialized(includeWitness: true),
              original.version == target.transaction.version, original.locktime == target.transaction.locktime,
              original.inputs.first == target.transaction.inputs.first,
              Array(original.outputs.dropLast()) == target.transaction.outputs else { throw LightningError.invalidState }
    }
    private static func validateRequest(id: Data, destination: Data, rate: Double, limit: UInt64, target: Target) throws {
        guard id.count == 32, ChannelTerms.validShutdown(destination, anySegwit: true) else { throw LightningError.invalidMessage }
        guard rate.isFinite, rate >= 1, rate <= 10_000, limit > target.parentFee,
              limit <= UInt64(BitcoinAmount.maximum) else { throw LightningError.invalidAmount }
    }
    private static func requiredFee(tx: Transaction, target: Target, rate: Double, replacing: AnchorFeeBump?) throws -> UInt64 {
        var sized = tx
        if let script = target.anchorScript { sized.inputs[0].witness = [Data(repeating: 0, count: 73), script.bytes] }
        for index in sized.inputs.indices.dropFirst() { sized.inputs[index].witness = [Data(repeating: 0, count: 64)] }
        let childSize = vsize(sized)
        let parentSize = target.kind == .commitment ? vsize(target.parent) : 0
        let targetFee = (rate * Double(childSize + parentSize)).rounded(.up)
        guard targetFee <= Double(BitcoinAmount.maximum) else { throw LightningError.invalidAmount }
        let deficit = UInt64(targetFee) > target.parentFee ? UInt64(targetFee) - target.parentFee : 0
        let relay = UInt64((rate * Double(childSize)).rounded(.up))
        let replacement = replacing.map { $0.feeSat + UInt64(childSize) } ?? 0
        return max(deficit, relay, replacement)
    }
    private static func validateLimit(fee: UInt64, parentFee: UInt64, limit: UInt64, replacing: AnchorFeeBump?) throws {
        guard fee <= limit - parentFee else { throw LightningError.invalidAmount }
        if let replacing {
            guard parentFee + fee <= replacing.totalFeeLimitSat else { throw LightningError.invalidAmount }
        }
    }
    static func vsize(_ tx: Transaction) -> Int {
        let base = tx.serialized(includeWitness: false).count
        return (base * 3 + tx.serialized(includeWitness: true).count + 3) / 4
    }
    static func validate(_ bump: AnchorFeeBump) throws {
        let tx = try Transaction.decode(bump.unsignedTransaction)
        let spent = try bump.spentOutputs()
        guard bump.id.count == 32, bump.channelID.count == 32, bump.selected.count <= 64,
              !bump.selected.isEmpty, tx.inputs.count == bump.selected.count + 1,
              Array(tx.inputs.dropFirst().map(\.previousOutput)) == bump.selected.map(\.outpoint),
              Set(tx.inputs.map(\.previousOutput)).count == tx.inputs.count else { throw LightningError.storageFailed }
        try validateAmounts(bump, tx: tx, spent: spent)
        if let raw = bump.signedTransaction {
            let signed = try Transaction.decode(raw)
            guard signed.serialized(includeWitness: false) == tx.serialized(includeWitness: false),
                  signed.inputs.allSatisfy({ !$0.witness.isEmpty }) else { throw LightningError.storageFailed }
        }
    }
    private static func validateAmounts(_ bump: AnchorFeeBump, tx: Transaction, spent: [SighashBIP341.SpentOutput]) throws {
        guard spent.allSatisfy({ $0.amount > 0 && $0.amount <= BitcoinAmount.maximum }),
              tx.outputs.allSatisfy({ $0.value > 0 && $0.value <= BitcoinAmount.maximum }) else { throw LightningError.storageFailed }
        let total = spent.reduce(UInt64(0)) { $0 + UInt64($1.amount) }
        let outputs = tx.outputs.reduce(UInt64(0)) { $0 + UInt64($1.value) }
        guard total >= outputs, total - outputs == bump.feeSat,
              bump.parentFeeSat <= bump.totalFeeLimitSat, bump.feeSat <= bump.totalFeeLimitSat - bump.parentFeeSat,
              bump.totalFeeLimitSat <= UInt64(BitcoinAmount.maximum) else { throw LightningError.storageFailed }
    }
}
