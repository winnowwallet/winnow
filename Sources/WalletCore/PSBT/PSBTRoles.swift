import Foundation
import NativeSecp256k1

/// PSBT roles (BIP370/BIP371): creator (unsigned wallet tx + UTXO data),
/// signer (PSBT_IN_TAP_KEY_SIG for the key path), combiner (union merge of
/// partial PSBTs), finalizer/extractor (witnesses → raw transaction).
extension PSBT {
    /// The Taproot key-origin metadata the creator attaches to an in/output:
    /// the x-only internal key and its full derivation path from the master
    /// fingerprint (BIP371 PSBT_*_TAP_BIP32_DERIVATION with zero leaf hashes).
    public struct TaprootKey: Equatable, Sendable {
        public var internalKey: Data
        public var masterFingerprint: UInt32
        public var path: [UInt32]

        public init(internalKey: Data, masterFingerprint: UInt32, path: [UInt32]) {
            self.internalKey = internalKey
            self.masterFingerprint = masterFingerprint
            self.path = path
        }

        var origin: KeyOrigin {
            KeyOrigin(leafHashes: [], masterFingerprint: masterFingerprint, path: path)
        }
    }

    /// Creator input: the spent output (amount + scriptPubKey → witness utxo)
    /// and, when ours, its Taproot key origin.
    public struct InputInfo: Equatable, Sendable {
        public var spentOutput: SighashBIP341.SpentOutput
        public var key: TaprootKey?

        public init(spentOutput: SighashBIP341.SpentOutput, key: TaprootKey? = nil) {
            self.spentOutput = spentOutput
            self.key = key
        }
    }

    /// Creator output metadata: key origin for wallet-owned (change) outputs.
    public struct OutputInfo: Equatable, Sendable {
        public var key: TaprootKey?

        public init(key: TaprootKey? = nil) {
            self.key = key
        }
    }

    // MARK: - Creator

    /// Creator role: a PSBTv2 from an unsigned transaction plus per-input UTXO
    /// data. Emits the BIP370 v2 fields (previous txid, output index, sequence,
    /// fallback locktime), PSBT_IN_WITNESS_UTXO (amount + scriptPubKey), an
    /// explicit PSBT_IN_SIGHASH_TYPE = SIGHASH_DEFAULT, and the BIP371 Taproot
    /// key fields for wallet-owned in/outputs.
    public init(unsignedTx tx: Transaction, inputs inputInfo: [InputInfo],
                outputs outputInfo: [OutputInfo]) throws {
        guard inputInfo.count == tx.inputs.count else {
            throw PSBTError.inconsistentCounts
        }
        guard outputInfo.count == tx.outputs.count else {
            throw PSBTError.inconsistentCounts
        }
        var globals: [KeyValue] = []
        globals.append(KeyValue(type: GlobalType.version, value: Self.uint32le(2)))
        globals.append(KeyValue(type: GlobalType.txVersion, value: Self.int32le(tx.version)))
        globals.append(KeyValue(type: GlobalType.fallbackLocktime, value: Self.uint32le(tx.locktime)))
        globals.append(KeyValue(type: GlobalType.inputCount, value: Self.compactSize(UInt64(tx.inputs.count))))
        globals.append(KeyValue(type: GlobalType.outputCount, value: Self.compactSize(UInt64(tx.outputs.count))))

        inputs = try zip(tx.inputs, inputInfo).map { input, info in
            guard info.spentOutput.amount >= 0 else { throw PSBTError.malformed("negative amount") }
            var pairs: [KeyValue] = []
            pairs.append(KeyValue(type: InType.previousTxid, value: input.previousOutput.txid))
            pairs.append(KeyValue(type: InType.outputIndex, value: Self.uint32le(input.previousOutput.vout)))
            pairs.append(KeyValue(type: InType.sequence, value: Self.uint32le(input.sequence)))
            pairs.append(KeyValue(type: InType.sighashType, value: Self.uint32le(0))) // SIGHASH_DEFAULT
            var utxo = Data()
            utxo.appendInt64(info.spentOutput.amount)
            utxo.appendVarData(info.spentOutput.scriptPubKey)
            pairs.append(KeyValue(type: InType.witnessUTXO, value: utxo))
            var result = Input(pairs: pairs)
            if let key = info.key {
                result.tapInternalKey = key.internalKey
                result.tapBIP32Derivation = [key.internalKey: key.origin]
            }
            return result
        }

        outputs = zip(tx.outputs, outputInfo).map { output, info in
            var result = Output(pairs: [
                KeyValue(type: OutType.amount, value: Self.int64le(output.value)),
                KeyValue(type: OutType.script, value: output.scriptPubKey),
            ])
            if let key = info.key {
                result.tapInternalKey = key.internalKey
                result.tapBIP32Derivation = [key.internalKey: key.origin]
            }
            return result
        }
        self.globals = globals
        // Canonical key order in memory, matching the wire format.
        self.globals.sort { $0.key.lexicographicallyPrecedes($1.key) }
        for index in inputs.indices { inputs[index].pairs.sort { $0.key.lexicographicallyPrecedes($1.key) } }
        for index in outputs.indices { outputs[index].pairs.sort { $0.key.lexicographicallyPrecedes($1.key) } }
    }

    // MARK: - Unsigned transaction

    /// The unsigned transaction described by the v2 fields (BIP370): inputs
    /// from previous-txid/output-index/sequence (default 0xFFFFFFFF), outputs
    /// from amount/script, version and locktime from the globals.
    public func unsignedTransaction() throws -> Transaction {
        var txInputs: [Transaction.Input] = []
        for (index, input) in inputs.enumerated() {
            guard let txid = input.previousTxid, txid.count == 32 else {
                throw PSBTError.missingField("input \(index) previous txid")
            }
            guard let vout = input.outputIndex else {
                throw PSBTError.missingField("input \(index) output index")
            }
            txInputs.append(Transaction.Input(previousOutput: Transaction.Outpoint(txid: txid, vout: vout),
                                              scriptSig: Data(),
                                              sequence: input.sequence ?? 0xFFFF_FFFF))
        }
        var txOutputs: [Transaction.Output] = []
        for (index, output) in outputs.enumerated() {
            guard let amount = output.amount, let script = output.script else {
                throw PSBTError.missingField("output \(index) amount/script")
            }
            txOutputs.append(Transaction.Output(value: amount, scriptPubKey: script))
        }
        return Transaction(version: txVersion, inputs: txInputs, outputs: txOutputs,
                           locktime: fallbackLocktime)
    }

    /// The spent outputs (amount + scriptPubKey) of every input, from the
    /// witness utxos — the BIP341 sighash inputs.
    public func spentOutputs() throws -> [SighashBIP341.SpentOutput] {
        try inputs.enumerated().map { index, input in
            guard let utxo = input.witnessUTXO else {
                throw PSBTError.missingField("input \(index) witness utxo")
            }
            return utxo
        }
    }

    // MARK: - Signer

    /// Signer role: adds PSBT_IN_TAP_KEY_SIG to input `index` (BIP371). The
    /// hash type comes from PSBT_IN_SIGHASH_TYPE (0/absent = SIGHASH_DEFAULT —
    /// this wallet always writes it explicitly); `tweakedPrivateKey` is the
    /// BIP86 tweaked secret for the input's internal key.
    public mutating func signKeyPath(input index: Int, tweakedPrivateKey: Data,
                                     auxiliaryRand: Data? = nil) throws {
        guard inputs.indices.contains(index) else {
            throw PSBTError.missingField("input \(index)")
        }
        let tx = try unsignedTransaction()
        let spentOutputs = try spentOutputs()
        let rawType = inputs[index].sighashType ?? 0
        guard rawType <= UInt32(UInt8.max) else { throw PSBTError.malformed("sighash type \(rawType)") }
        let hashType = SighashBIP341.HashType(rawValue: UInt8(rawType))
        // This wallet only signs sighash types that commit to every output.
        guard hashType.commitsToAllOutputs else {
            throw PSBTError.malformed("refusing non-DEFAULT/ALL sighash type \(rawType)")
        }
        let witness = try Signer.witness(tx: tx, inputIndex: index, spentOutputs: spentOutputs,
                                         tweakedPrivateKey: tweakedPrivateKey, hashType: hashType,
                                         auxiliaryRand: auxiliaryRand)
        inputs[index].tapKeySignature = witness[0]
    }

    // MARK: - MuSig2 roles — BIP373 transport (key path)

    /// Creator-side helper: attaches PSBT_IN_TAP_INTERNAL_KEY (the BIP328-
    /// derived, pre-TapTweak aggregate key) and PSBT_IN_MUSIG2_PARTICIPANT_PUBKEYS
    /// for a MuSig2 account input (BIP373). `participants` are the sorted
    /// compressed keys the session aggregates over.
    public mutating func attachMuSig2(input index: Int, internalKey: Data, aggregate: Data,
                                      participants: [Data]) throws {
        guard inputs.indices.contains(index) else { throw PSBTError.missingField("input \(index)") }
        guard internalKey.count == 32, aggregate.count == 33, !participants.isEmpty else {
            throw PSBTError.malformed("musig2 keys")
        }
        inputs[index].tapInternalKey = internalKey
        var all = inputs[index].musig2ParticipantPubKeys
        all[aggregate] = participants
        inputs[index].musig2ParticipantPubKeys = all
    }

    /// Round 1 (BIP373): attaches the caller's 66-byte public nonce.
    public mutating func attachMuSig2PubNonce(input index: Int, id: MuSig2KeyID, nonce: Data) throws {
        guard inputs.indices.contains(index) else { throw PSBTError.missingField("input \(index)") }
        guard nonce.count == 66 else { throw PSBTError.malformed("pubnonce length \(nonce.count)") }
        var nonces = inputs[index].musig2PubNonces
        nonces[id] = nonce
        inputs[index].musig2PubNonces = nonces
    }

    /// Builds the BIP327 session from the PSBT contents once every
    /// participant has attached a nonce: the aggregate nonce is the BIP327
    /// NonceAgg of the nonces in participant order. `message` is the BIP341
    /// key-path sighash; the tweak chain comes from the account descriptor
    /// (BIP328 path tweaks, then the x-only TapTweak).
    public func muSig2Session(input index: Int, aggregateKey: Data, tweaks: [Data],
                              isXOnlyTweaks: [Bool], message: Data) throws -> MuSig.Session {
        guard inputs.indices.contains(index) else { throw PSBTError.missingField("input \(index)") }
        guard let participants = inputs[index].musig2ParticipantPubKeys[aggregateKey] else {
            throw PSBTError.missingField("input \(index) musig2 participants")
        }
        let nonces = inputs[index].musig2PubNonces
        // Participant lists name the root aggregate; signing contributions
        // name the actual output key, after derivation and TapTweak (BIP373).
        let signingKey = try MuSig.aggregate(publicKeys: participants, tweaks: tweaks,
                                             isXOnlyTweaks: isXOnlyTweaks)
        var ordered: [Data] = []
        for participant in participants {
            guard let nonce = nonces[MuSig2KeyID(participant: participant, aggregate: signingKey)] else {
                throw PSBTError.missingField("input \(index) musig2 nonce for \(participant.hex)")
            }
            ordered.append(nonce)
        }
        return MuSig.Session(aggregateNonce: try MuSig.nonceAggregate(publicNonces: ordered),
                             publicKeys: participants, tweaks: tweaks,
                             isXOnlyTweaks: isXOnlyTweaks, message: message)
    }

    /// Round 2 (BIP373/BIP327): produces the caller's partial signature and
    /// attaches it after a successful partial self-verification. The secret
    /// nonce is zeroed by `MuSig.partialSign`.
    public mutating func signMuSig2(input index: Int, id: MuSig2KeyID, secretNonce: inout Data,
                                    secretKey: Data, session: MuSig.Session) throws {
        guard inputs.indices.contains(index) else { throw PSBTError.missingField("input \(index)") }
        let nonces = inputs[index].musig2PubNonces
        guard let ownNonce = nonces[id] else {
            throw PSBTError.missingField("input \(index) own musig2 nonce")
        }
        let partial = try MuSig.partialSign(secretNonce: &secretNonce, secretKey: secretKey, session: session)
        guard try MuSig.partialVerify(partialSignature: partial, publicNonce: ownNonce,
                                      publicKey: id.participant, session: session) else {
            throw PSBTError.malformed("self-produced partial signature failed verification")
        }
        var partials = inputs[index].musig2PartialSigs
        partials[id] = partial
        inputs[index].musig2PartialSigs = partials
    }

    /// Aggregation (BIP327 PartialSigAgg): verifies every partial, combines
    /// them into the 64-byte BIP340 signature over the tweaked aggregate key
    /// and stores it as PSBT_IN_TAP_KEY_SIG, ready for `finalize()`.
    public mutating func aggregateMuSig2(input index: Int, session: MuSig.Session) throws {
        guard inputs.indices.contains(index) else { throw PSBTError.missingField("input \(index)") }
        let partials = inputs[index].musig2PartialSigs
        let nonces = inputs[index].musig2PubNonces
        let aggregate = try MuSig.aggregate(publicKeys: session.publicKeys, tweaks: session.tweaks,
                                            isXOnlyTweaks: session.isXOnlyTweaks)
        var ordered: [Data] = []
        for participant in session.publicKeys {
            let id = MuSig2KeyID(participant: participant, aggregate: aggregate)
            guard let partial = partials[id], let nonce = nonces[id] else {
                throw PSBTError.missingField("input \(index) musig2 partial sig for \(participant.hex)")
            }
            // Reject a wrong-key or otherwise invalid partial before combining.
            guard try MuSig.partialVerify(partialSignature: partial, publicNonce: nonce,
                                          publicKey: participant, session: session) else {
                throw PSBTError.malformed("invalid partial signature from \(participant.hex)")
            }
            ordered.append(partial)
        }
        let signature = try MuSig.partialSigAggregate(partialSignatures: ordered, session: session)
        // The aggregate must be a valid BIP340 signature for the tweaked
        // aggregate key over the session message (the key-path sighash).
        let aggregateXonly = try MuSig.aggregateXonly(publicKeys: session.publicKeys,
                                                      tweaks: session.tweaks,
                                                      isXOnlyTweaks: session.isXOnlyTweaks)
        guard Secp256k1.Schnorr.verify(signature: signature, message: session.message, publicKey: aggregateXonly) else {
            throw PSBTError.malformed("aggregate signature failed verification")
        }
        // BIP341: a 64-byte witness signature means SIGHASH_DEFAULT; a non-default
        // type (only ALL survives keyPathSighash's guard) must append its byte,
        // or the finalized witness is consensus-invalid. Mirrors Signer.witness.
        let hashType = SighashBIP341.HashType(rawValue: UInt8(truncatingIfNeeded: inputs[index].sighashType ?? 0))
        inputs[index].tapKeySignature = hashType == .default ? signature : signature + Data([hashType.rawValue])
    }

    // MARK: - Combiner

    /// Combiner role (BIP370/BIP174): merges several partial PSBTs of the
    /// same unsigned transaction into one. The merge is the union of the
    /// key-value pairs of every map (globals, inputs, outputs); identical
    /// pairs dedupe, and the same key carrying two different values is a
    /// conflict and throws.
    public func combined(with others: [PSBT]) throws -> PSBT {
        let all = [self] + others
        let reference = try unsignedTransaction()
        guard allSatisfy(all, countsMatch), try allSatisfy(all, { try $0.unsignedTransaction() == reference })
        else { throw PSBTError.inconsistentCounts }

        func merge(_ maps: [[KeyValue]]) throws -> [KeyValue] {
            var merged: [Data: Data] = [:]
            for map in maps {
                for pair in map {
                    if let existing = merged[pair.key], existing != pair.value {
                        throw PSBTError.conflict(pair.key)
                    }
                    merged[pair.key] = pair.value
                }
            }
            return merged.sorted { $0.key.lexicographicallyPrecedes($1.key) }
                .map { KeyValue(key: $0.key, value: $0.value) }
        }

        var mergedInputs: [Input] = []
        var mergedOutputs: [Output] = []
        for index in inputs.indices {
            mergedInputs.append(Input(pairs: try merge(all.map { $0.inputs[index].pairs })))
        }
        for index in outputs.indices {
            mergedOutputs.append(Output(pairs: try merge(all.map { $0.outputs[index].pairs })))
        }
        return try PSBT(globals: merge(all.map(\.globals)), inputs: mergedInputs, outputs: mergedOutputs)
    }

    private func allSatisfy(_ psbts: [PSBT], _ predicate: (PSBT) throws -> Bool) rethrows -> Bool {
        for psbt in psbts where try !predicate(psbt) { return false }
        return true
    }

    private func countsMatch(_ other: PSBT) -> Bool {
        other.inputs.count == inputs.count && other.outputs.count == outputs.count
    }

    // MARK: - Finalizer / extractor

    /// Finalizer role: moves each input's signature data into
    /// PSBT_IN_FINAL_SCRIPTWITNESS and clears the in-progress fields (BIP174:
    /// finalizers remove partial data). Every input takes its single
    /// PSBT_IN_TAP_KEY_SIG, verified against the declared P2TR output first.
    public mutating func finalize() throws {
        let tx = try unsignedTransaction()
        let spentOutputs = try spentOutputs()
        var witnesses: [[Data]] = []
        for index in inputs.indices {
            if let signature = inputs[index].tapKeySignature {
                witnesses.append(try validatedKeyPathWitness(
                    input: index, signature: signature, tx: tx, spentOutputs: spentOutputs))
            } else {
                throw PSBTError.missingField("input \(index) tap key sig")
            }
        }
        // Commit only after every input validates. A bad later input must not
        // leave the PSBT half-finalized with earlier partial fields erased.
        for index in inputs.indices {
            inputs[index].finalScriptWitness = witnesses[index]
            inputs[index].pairs.removeAll {
                $0.type == InType.tapKeySignature || $0.type == InType.sighashType
                    || $0.type == InType.musig2PubNonce || $0.type == InType.musig2PartialSig
            }
        }
    }

    /// Validates an imported key-path signature against the PSBT's declared
    /// P2TR witness UTXO before moving it into the final witness. Trusted
    /// wallet policy must separately bind that declaration to the real coin;
    /// finalization proves document self-consistency, not chain ownership.
    private func validatedKeyPathWitness(input index: Int, signature: Data,
                                         tx: Transaction,
                                         spentOutputs: [SighashBIP341.SpentOutput]) throws -> [Data] {
        let hashType: SighashBIP341.HashType
        switch signature.count {
        case 64:
            hashType = .default
        case 65:
            hashType = SighashBIP341.HashType(rawValue: signature.last!)
        default:
            throw PSBTError.malformed("input \(index) tap key signature length")
        }
        guard hashType.commitsToAllOutputs,
              hashType != .default || signature.count == 64
        else { throw PSBTError.malformed("input \(index) unsafe tap key sighash type") }

        let script = spentOutputs[index].scriptPubKey
        guard script.count == 34, script[script.startIndex] == 0x51,
              script[script.index(after: script.startIndex)] == 0x20
        else { throw PSBTError.malformed("input \(index) witness utxo is not P2TR") }
        let sighash = try SighashBIP341.sighash(
            tx: tx, inputIndex: index, spentOutputs: spentOutputs, hashType: hashType)
        guard Secp256k1.Schnorr.verify(signature: Data(signature.prefix(64)), message: sighash,
                                       publicKey: Data(script.suffix(32)))
        else { throw PSBTError.malformed("input \(index) invalid tap key signature") }
        return [signature]
    }

    /// Extractor role: the fully-signed raw transaction.
    public func extractedTransaction() throws -> Transaction {
        var tx = try unsignedTransaction()
        for index in tx.inputs.indices {
            guard let witness = inputs[index].finalScriptWitness else {
                throw PSBTError.missingField("input \(index) final witness")
            }
            tx.inputs[index].witness = witness
        }
        return tx
    }

    // MARK: - LE helpers

    static func uint32le(_ value: UInt32) -> Data {
        var data = Data()
        data.appendUInt32(value)
        return data
    }

    static func int32le(_ value: Int32) -> Data {
        var data = Data()
        data.appendInt32(value)
        return data
    }

    static func int64le(_ value: Int64) -> Data {
        var data = Data()
        data.appendInt64(value)
        return data
    }

    static func compactSize(_ value: UInt64) -> Data {
        var data = Data()
        data.appendCompactSize(value)
        return data
    }
}
