import Foundation

/// The PSBT fields and roles a payjoin sender needs beyond the wallet's own
/// Taproot flow: the legacy and wrapped-segwit fields a receiver's inputs
/// may carry (BIP 174), finalizing only the sender's inputs of a proposal
/// whose receiver inputs arrive already final, and stripping the Original
/// PSBT down to what BIP 78 lets the receiver see.
///
/// Exercised by `PayjoinProposalTests` and `PSBTTests`.
extension PSBT {
    /// BIP 174 input types this extension reads.
    enum LegacyInType {
        static let nonWitnessUTXO: UInt8 = 0x00
        static let partialSignature: UInt8 = 0x02
        static let redeemScript: UInt8 = 0x04
        static let bip32Derivation: UInt8 = 0x06
        static let finalScriptSig: UInt8 = 0x07
    }

    enum LegacyOutType {
        static let bip32Derivation: UInt8 = 0x02
    }
}

extension PSBT.Input {
    /// PSBT_IN_NON_WITNESS_UTXO — the whole previous transaction.
    public var nonWitnessUTXO: Transaction? {
        guard let value = pair(type: PSBT.LegacyInType.nonWitnessUTXO)?.value else { return nil }
        return try? Transaction.decode(value)
    }

    /// PSBT_IN_FINAL_SCRIPTSIG.
    public var finalScriptSig: Data? {
        get { pair(type: PSBT.LegacyInType.finalScriptSig)?.value }
        set {
            guard let newValue else { remove(type: PSBT.LegacyInType.finalScriptSig); return }
            set(PSBT.KeyValue(type: PSBT.LegacyInType.finalScriptSig, value: newValue))
        }
    }

    /// Whether the input carries a final scriptSig or witness.
    public var isFinalized: Bool {
        finalScriptSig != nil || finalScriptWitness != nil
    }

    /// Whether any key-path information is present (BIP 174 or BIP 371).
    public var carriesKeyPaths: Bool {
        pairs.contains { $0.type == PSBT.LegacyInType.bip32Derivation || $0.type == PSBT.InType.tapBIP32Derivation }
    }

    /// Whether any partial signature is present (ECDSA or Taproot).
    public var carriesPartialSignatures: Bool {
        pairs.contains {
            $0.type == PSBT.LegacyInType.partialSignature || $0.type == PSBT.InType.tapKeySignature
                || $0.type == PSBT.InType.tapScriptSignature
        }
    }

    /// The output this input spends, from the witness UTXO or, failing that,
    /// the non-witness UTXO whose txid must match the input's previous txid
    /// (a receiver could otherwise lie about an amount).
    public func spentOutput() -> SighashBIP341.SpentOutput? {
        if let utxo = witnessUTXO { return utxo }
        guard let previous = nonWitnessUTXO, let txid = previousTxid, previous.txid == txid,
              let vout = outputIndex, previous.outputs.indices.contains(Int(vout)) else { return nil }
        let output = previous.outputs[Int(vout)]
        return SighashBIP341.SpentOutput(amount: output.value, scriptPubKey: output.scriptPubKey)
    }
}

extension PSBT.Output {
    /// Whether any key-path information is present (BIP 174 or BIP 371).
    public var carriesKeyPaths: Bool {
        pairs.contains { $0.type == PSBT.LegacyOutType.bip32Derivation || $0.type == PSBT.OutType.tapBIP32Derivation }
    }
}

extension PSBT {
    /// Finalizer role for a payjoin proposal: moves the key-path signature of
    /// each listed input into its final witness (verified against the
    /// declared P2TR output, as `finalize()` does) and leaves every other
    /// input exactly as the receiver finalized it.
    public mutating func finalizeKeyPath(inputs indices: Set<Int>) throws {
        let tx = try unsignedTransaction()
        let spentOutputs = try self.inputs.enumerated().map { index, input -> SighashBIP341.SpentOutput in
            guard let spent = input.spentOutput() else { throw PSBTError.missingField("input \(index) utxo") }
            return spent
        }
        var witnesses: [Int: [Data]] = [:]
        for index in indices.sorted() {
            guard inputs.indices.contains(index), let signature = inputs[index].tapKeySignature else {
                throw PSBTError.missingField("input \(index) tap key sig")
            }
            witnesses[index] = try validatedKeyPathWitness(input: index, signature: signature, tx: tx,
                                                           spentOutputs: spentOutputs)
        }
        for (index, witness) in witnesses {
            inputs[index].finalScriptWitness = witness
            inputs[index].pairs.removeAll { $0.type == InType.tapKeySignature || $0.type == InType.sighashType }
        }
    }

    /// The Original PSBT as BIP 78 wants it: UTXO data and final witnesses
    /// kept, key origins, internal keys and every proprietary or unknown
    /// field dropped.
    public func strippedForPayjoin() -> PSBT {
        var copy = self
        let keepInput: Set<UInt8> = [InType.witnessUTXO, LegacyInType.nonWitnessUTXO, LegacyInType.finalScriptSig,
                                     InType.finalScriptWitness, InType.previousTxid, InType.outputIndex, InType.sequence]
        let keepOutput: Set<UInt8> = [OutType.amount, OutType.script]
        let keepGlobal: Set<UInt8> = [GlobalType.version, GlobalType.txVersion, GlobalType.fallbackLocktime,
                                      GlobalType.inputCount, GlobalType.outputCount]
        copy.globals.removeAll { !keepGlobal.contains($0.type) }
        for index in copy.inputs.indices { copy.inputs[index].pairs.removeAll { !keepInput.contains($0.type) } }
        for index in copy.outputs.indices { copy.outputs[index].pairs.removeAll { !keepOutput.contains($0.type) } }
        return copy
    }
}
