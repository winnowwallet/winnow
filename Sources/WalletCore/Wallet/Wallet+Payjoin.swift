import Foundation

/// The wallet's side of a payjoin send: the sender context for a prepared
/// send, signing a checked proposal with the same keys that signed the
/// original, and committing the payjoin transaction instead of the original.
///
/// Exercised by `PayjoinWalletTests` and the app's `PayjoinSendFlowTests`.
extension Wallet {
    /// BIP 78's recommended fee contribution: the original fee rate over
    /// 110 vbytes, roughly one more input of any common type.
    public static let feeContributionVBytes = 110.0

    /// The most the receiver may take from `change` for fees: the recommended
    /// contribution at this rate, capped so the change stays above dust;
    /// nothing without change. Pure, so the review can show the same number
    /// the wallet later offers.
    public static func payjoinFeeContribution(feeRateSatPerVByte: Double, change: Payment?) -> Int64 {
        guard let change else { return 0 }
        let recommended = Int64((feeRateSatPerVByte * feeContributionVBytes).rounded(.up))
        let dust = CoinSelection.dustThreshold(scriptPubKey: change.scriptPubKey)
        return max(0, min(recommended, change.amount - dust))
    }

    /// The sender context for `prepared`: the payee output it pays, the
    /// change output the receiver may draw fees from, and the fee rate the
    /// proposal must keep.
    public func payjoinContext(for prepared: PreparedSend, payee: Payment,
                               feeRateSatPerVByte: Double) throws -> PayjoinContext {
        let contribution = Self.payjoinFeeContribution(feeRateSatPerVByte: feeRateSatPerVByte, change: prepared.change)
        let feeOutputIndex = contribution > 0 ? prepared.changeOutputIndex.map(Int.init) : nil
        return try PayjoinContext(original: prepared.built.psbt, payeeScript: payee.scriptPubKey,
                                  payeeAmount: payee.amount, feeOutputIndex: feeOutputIndex,
                                  maxFeeContribution: contribution, minFeeRateSatPerVByte: feeRateSatPerVByte)
    }

    /// Signs the sender's inputs of a checked proposal with the keys of the
    /// coins `prepared` selected, finalizes only those inputs, verifies the
    /// minimum fee rate on the result, and returns the transaction to
    /// broadcast. Nothing in wallet state changes.
    public func signPayjoinProposal(_ checked: CheckedProposal, prepared: PreparedSend) throws -> Transaction {
        var psbt = checked.psbt
        guard checked.senderInputIndices.count == prepared.selected.count else {
            throw PayjoinProposalError.senderInputsMissingOrShuffled
        }
        let signingAccount = try accountPrivateKey()
        for (position, index) in checked.senderInputIndices.enumerated() {
            let utxo = prepared.selected[position]
            guard psbt.inputs[index].previousTxid == utxo.txid, psbt.inputs[index].outputIndex == utxo.vout else {
                throw PayjoinProposalError.senderInputsMissingOrShuffled
            }
            try psbt.signKeyPath(input: index, tweakedPrivateKey: tweakedPrivateKey(chain: utxo.chain, index: utxo.index,
                                                                           account: signingAccount))
        }
        try psbt.finalizeKeyPath(inputs: Set(checked.senderInputIndices))
        let transaction = try psbt.extractedTransaction()
        try checked.verifyFeeRate(of: transaction)
        try Self.checkStandardSize(transaction)
        return transaction
    }

    /// Commits a payjoin send: the selected coins are spent by the payjoin
    /// transaction, the change output (found by script, since the receiver
    /// may have inserted outputs before it) enters as pending with the
    /// amount it ended up with, and history records the fee the sender paid
    /// (the original fee plus the contribution). No `PendingSend` is kept:
    /// the receiver's inputs cannot be re-signed, so the payment has no
    /// fee bump. Call only after the broadcaster accepted the transaction.
    public func commitPayjoin(_ prepared: PreparedSend, payee: Payment, transaction signed: Transaction,
                              checked: CheckedProposal) throws {
        var updated = state
        for index in updated.allUtxos.indices
        where prepared.selected.contains(where: { $0.outpoint == updated.allUtxos[index].outpoint }) {
            updated.allUtxos[index].spent = WalletUTXO.SpentMarker(spentBy: signed.txid, height: nil)
        }
        var received: Int64 = 0
        if let change = prepared.change {
            guard let vout = signed.outputs.firstIndex(where: { $0.scriptPubKey == change.scriptPubKey }),
                  signed.outputs[vout].value >= change.amount - checked.contributedFee
            else { throw WalletError.changeOutputMissing }
            received = signed.outputs[vout].value
            updated.allUtxos.append(WalletUTXO(txid: signed.txid, vout: UInt32(vout), amount: received,
                                               scriptPubKey: change.scriptPubKey, chain: .change,
                                               index: prepared.changeIndex, height: 0))
            updated.nextChangeIndex += 1
        }
        var outputs = try classifyOutputs(of: signed)
        outputs.annotatePayjoin(payee: payee)
        updated.history.append(HistoryEntry(txid: signed.txid, height: 0, received: received,
                                            spent: prepared.selected.reduce(0) { $0 + $1.amount },
                                            fee: prepared.fee + checked.contributedFee,
                                            rawTransaction: signed.serialized(includeWitness: false),
                                            fundingScripts: FundingSources.fundingScripts(of: signed),
                                            outputs: outputs))
        try persist(updated)
        state = updated
    }
}
