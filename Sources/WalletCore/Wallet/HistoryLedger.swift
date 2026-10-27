import Foundation

/// The history rules the wallet and a multisig account share, as pure
/// functions over `[HistoryEntry]`: what a confirmed transaction records,
/// how a pending entry confirms in place, which outputs are change or
/// external, and what a reorg re-pends or drops. `Wallet` keeps fee-rate
/// sampling, pending sends and replacement reconciliation around these;
/// `MultisigStore` keeps coins, drafts and in-flight spends. One reorg fix
/// serves both. Exercised by WalletCoreTests/HistoryLedgerTests, and through
/// the callers by WalletTests, WalletReorgTests and AppTests/MultisigStoreTests.
public enum HistoryLedger {
    /// The fee a spend paid, known only when every input was ours (the BIP341
    /// sighash commits to amounts, so our own spends qualify): inputs minus
    /// outputs, and only when that is positive.
    public static func exactFee(spent: Int64, of tx: Transaction, allInputsOurs: Bool) -> Int64? {
        guard allInputsOurs, spent > 0 else { return nil }
        let candidate = spent - tx.outputs.reduce(0) { $0 + $1.value }
        return candidate > 0 ? candidate : nil
    }

    /// Confirms `tx` into `history`. A known entry, a pending spend reaching
    /// its block or a re-pended one, takes the height, the block hash, its
    /// bytes and funding scripts, and keeps a breakdown only while it still
    /// describes those bytes; an unknown transaction is appended without a
    /// breakdown. Returns whether the entry was known.
    @discardableResult
    public static func record(_ history: inout [HistoryEntry], tx: Transaction, txid: Data, height: UInt32,
                              blockHash: Data, received: Int64, spent: Int64, fee: Int64?) -> Bool {
        if let existing = history.firstIndex(where: { $0.txid == txid }) {
            history[existing].height = height
            history[existing].blockHash = blockHash
            history[existing].rawTransaction = tx.serialized(includeWitness: false)
            history[existing].fundingScripts = FundingSources.fundingScripts(of: tx)
            history[existing].outputs = agreeing(history[existing].outputs, with: tx)
            return true
        }
        history.append(HistoryEntry(txid: txid, height: height, received: received, spent: spent, fee: fee,
                                    rawTransaction: tx.serialized(includeWitness: false),
                                    fundingScripts: FundingSources.fundingScripts(of: tx), blockHash: blockHash))
        return false
    }

    /// The breakdown an entry may keep once its bytes are known. A breakdown
    /// that arrived without bytes, an imported entry's display metadata, is
    /// dropped when the real transaction contradicts it, rather than
    /// persisted: `HistoryEntry` refuses to decode an entry whose metadata
    /// disagrees with its transaction, and a state file the wallet cannot
    /// reopen is worse than a payment without recipient names.
    public static func agreeing(_ outputs: HistoryEntry.Outputs?, with tx: Transaction) -> HistoryEntry.Outputs? {
        guard let outputs, (try? outputs.validate(against: tx)) != nil else { return nil }
        return outputs
    }

    /// Positive outputs classified by whose script they pay: the owner's
    /// change vouts, external recipients in transaction order, and the
    /// owner's receive outputs left out.
    public static func classifyOutputs(of transaction: Transaction,
                                       chain: (Data) -> AddressChain?) -> HistoryEntry.Outputs {
        var result = HistoryEntry.Outputs()
        for (vout, output) in transaction.outputs.enumerated() where output.value > 0 {
            switch chain(output.scriptPubKey) {
            case .change: result.change.append(UInt32(vout))
            case .receive: continue
            case nil:
                result.external.append(.init(vout: UInt32(vout), amount: output.value,
                                             scriptPubKey: output.scriptPubKey))
            }
        }
        return result
    }

    /// A reorg below `forkHeight`. A disconnected spender is straight back in
    /// every mempool that saw it, so its entry re-pends (height 0, no block
    /// hash) and its txid is returned so the caller keeps its input
    /// reservations (#157); a pure receive drops with its coins, and the
    /// rescan from the fork re-finds whichever survive. A pure function of
    /// the fork height, so a repeat changes nothing.
    public static func rewind(_ history: inout [HistoryEntry], above forkHeight: UInt32) -> Set<Data> {
        var repended: Set<Data> = []
        for index in history.indices where history[index].height > forkHeight && history[index].spent > 0 {
            repended.insert(history[index].txid)
            history[index].height = 0
            history[index].blockHash = nil
        }
        history.removeAll { $0.height > forkHeight }
        return repended
    }
}
