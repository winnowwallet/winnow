import Foundation
import NativeSecp256k1

public enum MuSig2AccountError: Error, Equatable {
    /// Not a supported account shape: `tr(musig(XPUB, XPUB, ...)/<0;1>/*)`.
    case invalidDescriptor(String)
    /// The coin's scriptPubKey doesn't match the descriptor at its coordinates.
    case scriptMismatch(index: UInt32, choice: Int)
    /// None of the participant keys derive from the signing key given.
    case noParticipantKey(input: Int)
    /// Round 2 without this device's round-1 secret nonce, which lives only
    /// in memory: the nonce round must start again.
    case missingNonce(input: Int)
    /// An imported spend proposal is not an exact, safe spend of known coins.
    case invalidSpend(String)
}

extension MuSig2AccountError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        // `reason` is always a developer-authored literal, never descriptor
        // text, which carries key material.
        case let .invalidDescriptor(reason): "The MuSig2 descriptor is invalid: \(reason)."
        case let .scriptMismatch(index, choice):
            "MuSig2 key \(choice)/\(index) does not produce the stored Bitcoin output."
        case let .noParticipantKey(input): "This device holds no participant key for input \(input + 1)."
        case let .missingNonce(input):
            "This device has no nonce for input \(input + 1) from this session. Add a new nonce first."
        case let .invalidSpend(reason): "This MuSig2 spend is unsafe: \(reason)."
        }
    }
}

/// One stored MuSig2 account: the descriptor, its address frontiers and the
/// coins the wallet's filter scan found for it. Spent coins stay as
/// tombstones so a reorg can restore them. The JSON keys match the vault
/// records of the shared-account Winnow, so its backups of MuSig2 accounts
/// restore here.
public struct MuSig2AccountRecord: Codable, Equatable, Identifiable, Sendable {
    /// The descriptor's BIP380 checksum.
    public var id: String
    public var name: String
    public var descriptor: String
    public var createdAtHeight: UInt32
    public var nextReceiveIndex: UInt32 = 0
    public var nextChangeIndex: UInt32 = 0
    public var allUtxos: [WalletUTXO] = []

    public init(id: String, name: String, descriptor: String, createdAtHeight: UInt32,
                nextReceiveIndex: UInt32 = 0, nextChangeIndex: UInt32 = 0,
                allUtxos: [WalletUTXO] = []) {
        self.id = id
        self.name = name
        self.descriptor = descriptor
        self.createdAtHeight = createdAtHeight
        self.nextReceiveIndex = nextReceiveIndex
        self.nextChangeIndex = nextChangeIndex
        self.allUtxos = allUtxos
    }

    public var utxos: [WalletUTXO] { allUtxos.filter { !$0.isSpent } }
    public var balance: Int64 { utxos.reduce(0) { $0 + $1.amount } }

    private enum CodingKeys: String, CodingKey {
        case id, name, descriptor, createdAtHeight, nextReceiveIndex, nextChangeIndex
        case allUtxos = "utxos"
    }
}

/// A raw n-of-n MuSig2 account: `tr(musig(XPUB, XPUB, ...)/<0;1>/*)`, a
/// Taproot key-path output whose internal key is the BIP327 aggregate of the
/// participants (BIP390, BIP328). Every participant must sign every spend.
/// Spends travel as PSBT text with the BIP373 fields: the creator builds the
/// PSBT, each participant adds a nonce (round 1), then a partial signature
/// (round 2), and the aggregate becomes the single key-path signature.
public struct MuSig2Account: Sendable {
    /// A descriptor coordinate that may legitimately receive money back into
    /// this account. PSBT output metadata is never trusted for ownership.
    public struct OutputCoordinate: Hashable, Sendable {
        public var choice: Int
        public var index: UInt32

        public init(choice: Int, index: UInt32) {
            self.choice = choice
            self.index = index
        }
    }

    public struct SpendReview: Equatable, Sendable {
        public struct Output: Equatable, Sendable {
            public var amount: Int64
            public var scriptPubKey: Data
            public var isAccountOwned: Bool
        }

        public var outputs: [Output]
        public var inputTotal: Int64
        public var outputTotal: Int64
        public var fee: Int64
    }

    public let descriptor: Descriptor
    public let network: BitcoinNetwork
    public let participants: [Descriptor.SingleKey]
    public let derivation: Descriptor.Derivation

    /// The only `musig()` suffix accepted, and the only participant shape:
    /// fixed templates are what make signer independence provable (see
    /// `requireDistinctSigners`).
    static let accountSuffix = Descriptor.Derivation([.multipath([0, 1]), .wildcard(hardened: false)])

    public init(descriptor: Descriptor, network: BitcoinNetwork) throws {
        guard case let .trMuSig(muSig) = descriptor.expression else {
            throw MuSig2AccountError.invalidDescriptor("expected tr(musig(…)/<0;1>/*)")
        }
        guard muSig.derivation == Self.accountSuffix else {
            throw MuSig2AccountError.invalidDescriptor("the musig() suffix must be /<0;1>/*")
        }
        guard muSig.participants.count >= 2 else {
            throw MuSig2AccountError.invalidDescriptor("a MuSig2 account needs at least two participants")
        }
        for participant in muSig.participants {
            try Self.requireAccountKey(participant, network: network)
        }
        self.descriptor = descriptor
        self.network = network
        participants = muSig.participants
        derivation = muSig.derivation
        try requireDistinctSigners()
    }

    public init(_ string: String, network: BitcoinNetwork) throws {
        try self.init(descriptor: Descriptor(string), network: network)
    }

    /// The account's stable identifier: the descriptor's BIP380 checksum.
    public var id: String { String(descriptor.serialized().suffix(8)) }

    static func hdNetwork(for network: BitcoinNetwork) -> HDKey.Network {
        network == .mainnet ? .mainnet : .testnet
    }

    /// A participant as accepted here: an extended public key with its
    /// origin, on this network, without a suffix of its own. The origin must
    /// describe the key supplied: as many steps as the key is deep, ending at
    /// the key's own child index.
    private static func requireAccountKey(_ single: Descriptor.SingleKey, network: BitcoinNetwork) throws {
        guard case let .extended(key, keyNetwork) = single.base, key.privateKey == nil,
              let origin = single.origin else {
            throw MuSig2AccountError.invalidDescriptor("every participant must be an extended public key carrying its origin")
        }
        guard origin.path.count == Int(key.depth), key.depth == 0 || origin.path.last == key.childIndex else {
            throw MuSig2AccountError.invalidDescriptor("a participant's origin path does not match its key")
        }
        guard keyNetwork == hdNetwork(for: network) else {
            throw MuSig2AccountError.invalidDescriptor("a participant's extended key belongs to a different network")
        }
        guard single.derivation.elements.isEmpty else {
            throw MuSig2AccountError.invalidDescriptor("a participant may not carry its own derivation suffix")
        }
    }

    /// An n-of-n account is only n-of-n if its participants are n distinct
    /// keys: `musig(K, K)` is spendable by whoever holds K alone. Keys are
    /// compared as derived material, so relabelling an origin cannot disguise
    /// a repeat; with no participant suffixes the comparison is exhaustive.
    private func requireDistinctSigners() throws {
        var seen: Set<Data> = []
        for participant in participants {
            guard case let .extended(key, _) = participant.base, seen.insert(key.publicKey).inserted else {
                throw MuSig2AccountError.invalidDescriptor(
                    "the same signing key appears more than once, so this account needs fewer signers than it claims")
            }
        }
    }

    /// Whether one participant is this account public key, whatever origin
    /// label the descriptor gives it.
    public func includes(accountKey: HDKey) -> Bool {
        participants.contains { participant in
            guard case let .extended(base, _) = participant.base else { return false }
            return base.publicKey == accountKey.publicKey
        }
    }

    /// Whether `key` (a master or BIP86 account key) holds one participant.
    public func hasParticipant(for key: HDKey) -> Bool {
        participants.contains { (try? Self.secret(for: $0, from: key)) != nil }
    }

    // MARK: - Watching

    /// scriptPubKey at (multipath choice, index): choice 0 receive, 1 change.
    public func scriptPubKey(index: UInt32, choice: Int = 0) throws -> Data {
        try descriptor.derived(index: index, bitcoinNetwork: network)[choice].scriptPubKey
    }

    public func address(index: UInt32, choice: Int = 0) throws -> String {
        try descriptor.derived(index: index, bitcoinNetwork: network)[choice].address
    }

    /// Both multipath choices for indices 0..<count.
    public func watchScripts(upTo count: UInt32) throws -> [Data] {
        var scripts: [Data] = []
        for index in 0 ..< count {
            for output in try descriptor.derived(index: index, bitcoinNetwork: network) {
                scripts.append(output.scriptPubKey)
            }
        }
        return scripts
    }

    // MARK: - Review

    /// Validates a PSBT before it is shown, signed, finalized or broadcast:
    /// every input is a unique known coin of this account with the exact
    /// amount and script the sighash commits to and the expected MuSig2
    /// fields; every signature commits to all outputs; amounts are valid; the
    /// fee is at most 10% of the inputs. Output ownership comes only from
    /// matching scripts against caller-supplied coordinates.
    public func reviewSpend(_ psbt: PSBT, knownUTXOs: [WalletUTXO],
                            ownedOutputCoordinates: [OutputCoordinate],
                            chainTip: UInt32) throws -> SpendReview {
        guard !psbt.inputs.isEmpty else { throw MuSig2AccountError.invalidSpend("it has no inputs") }
        guard !psbt.outputs.isEmpty, psbt.outputs.count <= 1_000 else {
            throw MuSig2AccountError.invalidSpend("it has no outputs or more than 1,000")
        }
        guard psbt.txVersion == 1 || psbt.txVersion == 2 else {
            throw MuSig2AccountError.invalidSpend("transaction version \(psbt.txVersion) is not supported")
        }
        let inputTotal = try reviewedInputTotal(of: psbt, knownUTXOs: knownUTXOs, chainTip: chainTip)
        let outputs = try reviewedOutputs(of: psbt, inputTotal: inputTotal,
                                          ownedOutputCoordinates: ownedOutputCoordinates)
        let fee = inputTotal - outputs.total
        try Self.checkFeeCeiling(fee: fee, inputTotal: inputTotal)
        return SpendReview(outputs: outputs.reviewed, inputTotal: inputTotal, outputTotal: outputs.total, fee: fee)
    }

    private static let maxMoney: Int64 = 2_100_000_000_000_000

    /// One rule for the creator and every reviewer: at most 10% of the
    /// inputs may go to the miner.
    private static func checkFeeCeiling(fee: Int64, inputTotal: Int64) throws {
        guard fee <= inputTotal / 10 else {
            throw MuSig2AccountError.invalidSpend("the \(fee)-sat fee exceeds the 10% safety limit for these inputs")
        }
    }

    private func reviewedInputTotal(of psbt: PSBT, knownUTXOs: [WalletUTXO], chainTip: UInt32) throws -> Int64 {
        var seen: Set<Transaction.Outpoint> = []
        var total: Int64 = 0
        for (inputIndex, input) in psbt.inputs.enumerated() {
            guard let txid = input.previousTxid, txid.count == 32, let vout = input.outputIndex else {
                throw MuSig2AccountError.invalidSpend("input \(inputIndex + 1) has no complete outpoint")
            }
            let outpoint = Transaction.Outpoint(txid: txid, vout: vout)
            guard seen.insert(outpoint).inserted else {
                throw MuSig2AccountError.invalidSpend("input \(inputIndex + 1) repeats an earlier outpoint")
            }
            guard let known = knownUTXOs.first(where: { $0.outpoint == outpoint }) else {
                throw MuSig2AccountError.invalidSpend("input \(inputIndex + 1) is not an available coin of this account")
            }
            try checkInput(input, inputIndex: inputIndex, utxo: known, chainTip: chainTip)
            let (sum, overflow) = total.addingReportingOverflow(known.amount)
            guard !overflow, sum <= Self.maxMoney else {
                throw MuSig2AccountError.invalidSpend("input amounts exceed Bitcoin's supply")
            }
            total = sum
        }
        return total
    }

    private func checkInput(_ input: PSBT.Input, inputIndex: Int, utxo known: WalletUTXO, chainTip: UInt32) throws {
        guard known.amount > 0, known.amount <= Self.maxMoney,
              let claimed = input.witnessUTXO, claimed == known.spentOutput else {
            throw MuSig2AccountError.invalidSpend("input \(inputIndex + 1) has the wrong amount or locking script")
        }
        if known.isCoinbase {
            let matureAt = known.height + Wallet.coinbaseMaturity - 1
            guard chainTip >= matureAt else {
                throw MuSig2AccountError.invalidSpend(
                    "input \(inputIndex + 1) spends a coinbase that matures in \(matureAt - chainTip) blocks")
            }
        }
        guard try scriptPubKey(index: known.index, choice: known.chain.rawValue) == known.scriptPubKey else {
            throw MuSig2AccountError.invalidSpend("input \(inputIndex + 1) does not belong to this descriptor")
        }
        let rawSighash = input.sighashType ?? 0
        guard rawSighash == 0 || rawSighash == 1 else {
            throw MuSig2AccountError.invalidSpend("input \(inputIndex + 1) does not commit to every output")
        }
        let context = try muSig2Context(choice: known.chain.rawValue, index: known.index)
        guard input.tapInternalKey == context.internalKey,
              input.musig2ParticipantPubKeys.count == 1,
              input.musig2ParticipantPubKeys[context.aggregate] == context.participants else {
            throw MuSig2AccountError.invalidSpend("input \(inputIndex + 1) changes the MuSig2 participants")
        }
    }

    private func reviewedOutputs(of psbt: PSBT, inputTotal: Int64, ownedOutputCoordinates: [OutputCoordinate])
        throws -> (reviewed: [SpendReview.Output], total: Int64) {
        let candidates = Array(Set(ownedOutputCoordinates.filter { (0 ... 1).contains($0.choice) }))
        guard candidates.count <= 1_024 else {
            throw MuSig2AccountError.invalidSpend("too many candidate account output paths")
        }
        let owned = Set(try candidates.map { try scriptPubKey(index: $0.index, choice: $0.choice) })
        var total: Int64 = 0
        var reviewed: [SpendReview.Output] = []
        for (outputIndex, output) in psbt.outputs.enumerated() {
            guard let amount = output.amount, amount > 0, amount <= Self.maxMoney,
                  let script = output.script, !script.isEmpty else {
                throw MuSig2AccountError.invalidSpend("output \(outputIndex + 1) has an invalid amount or script")
            }
            let (sum, overflow) = total.addingReportingOverflow(amount)
            guard !overflow, sum <= Self.maxMoney else {
                throw MuSig2AccountError.invalidSpend("output amounts exceed Bitcoin's supply")
            }
            total = sum
            reviewed.append(SpendReview.Output(amount: amount, scriptPubKey: script, isAccountOwned: owned.contains(script)))
        }
        guard total <= inputTotal else { throw MuSig2AccountError.invalidSpend("outputs exceed its known inputs") }
        return (reviewed, total)
    }

    // MARK: - Creating a spend

    /// Builds the unsigned spend PSBT: coin selection, the transaction with an
    /// anti-fee-sniping locktime, the BIP373 participant fields on every input
    /// and the internal key on the change output.
    public func createSpend(utxos: [WalletUTXO], payments: [Payment], changeIndex: UInt32,
                            feeRateSatPerVByte: Double, chainTip: UInt32,
                            randomness: @Sendable () -> Double = { Double.random(in: 0 ..< 1) }) throws -> PSBT {
        for utxo in utxos {
            guard try scriptPubKey(index: utxo.index, choice: utxo.chain.rawValue) == utxo.scriptPubKey else {
                throw MuSig2AccountError.scriptMismatch(index: utxo.index, choice: utxo.chain.rawValue)
            }
        }
        let changeScript = try scriptPubKey(index: changeIndex, choice: AddressChain.change.rawValue)
        // One 64-byte aggregate signature per input, like any key-path spend.
        let selection = try CoinSelection.select(utxos: utxos, payments: payments, changeScriptPubKey: changeScript,
                                                 feeRateSatPerVByte: feeRateSatPerVByte)
        try Self.checkFeeCeiling(fee: selection.fee, inputTotal: selection.selected.reduce(0) { $0 + $1.amount })
        let change = selection.changeAmount.map { Payment(amount: $0, scriptPubKey: changeScript) }
        let tx = try TransactionBuilder.build(
            inputs: selection.selected.map(\.outpoint), payments: payments, change: change,
            locktime: TransactionBuilder.antiFeeSnipingLocktime(tip: chainTip, randomness: randomness))
        var psbt = try PSBT(unsignedTx: tx,
                            inputs: selection.selected.map { PSBT.InputInfo(spentOutput: $0.spentOutput) },
                            outputs: tx.outputs.map { _ in PSBT.OutputInfo() })
        for (index, utxo) in selection.selected.enumerated() {
            let context = try muSig2Context(choice: utxo.chain.rawValue, index: utxo.index)
            try psbt.attachMuSig2(input: index, internalKey: context.internalKey,
                                  aggregate: context.aggregate, participants: context.participants)
        }
        if let change {
            let changeContext = try muSig2Context(choice: AddressChain.change.rawValue, index: changeIndex)
            for (outputIndex, output) in tx.outputs.enumerated()
            where output.scriptPubKey == change.scriptPubKey && output.value == change.amount {
                psbt.outputs[outputIndex].tapInternalKey = changeContext.internalKey
            }
        }
        return psbt
    }

    // MARK: - MuSig2 signing

    /// The signing context of the input at (choice, index): sorted participant
    /// keys, the root aggregate, the BIP328-derived internal key and the BIP327
    /// tweak chain (path tweaks plain, then the BIP341 TapTweak x-only).
    public struct MuSig2Context: Equatable, Sendable {
        public var choice: Int
        public var index: UInt32
        public var participants: [Data]
        public var aggregate: Data
        public var internalKey: Data
        public var tweaks: [Data]
        public var isXOnlyTweaks: [Bool]
        /// The final compressed output key, which identifies BIP373 nonces and partials.
        public var signingKey: Data
        public var outputKey: Data { Data(signingKey.dropFirst()) }
    }

    /// Computes the context, cross-checked against the descriptor's own
    /// scriptPubKey at the same coordinates.
    public func muSig2Context(choice: Int, index: UInt32) throws -> MuSig2Context {
        guard case let .trMuSig(muSig) = descriptor.expression else {
            throw MuSig2AccountError.invalidDescriptor("not a musig() account")
        }
        let sorted = MuSig.keySort(try descriptor.participantKeys(muSig, index: index, choice: choice))
        let aggregate = try MuSig.aggregate(sorted)
        var synthetic = try MuSig.syntheticExtendedKey(aggregatePublicKey: aggregate)
        var tweaks: [Data] = []
        var isXOnly: [Bool] = []
        for element in derivation.elements {
            let step: UInt32
            switch element {
            case let .step(value): step = value
            case let .multipath(values): step = values[choice]
            case let .wildcard(hardened):
                guard !hardened else { throw MuSig2AccountError.invalidDescriptor("hardened musig wildcard") }
                step = index
            }
            tweaks.append(MuSig.bip328Tweak(chainCode: synthetic.chainCode,
                                            aggregatePublicKey: synthetic.publicKey, index: step))
            isXOnly.append(false)
            synthetic = try synthetic.child(at: step)
        }
        let internalKey = Data(synthetic.publicKey.dropFirst())
        tweaks.append(Taproot.tweak(internalKey: internalKey, merkleRoot: nil))
        isXOnly.append(true)
        let signingKey = try MuSig.aggregate(publicKeys: sorted, tweaks: tweaks, isXOnlyTweaks: isXOnly)
        guard try scriptPubKey(index: index, choice: choice) == Data([0x51, 0x20]) + Data(signingKey.dropFirst()) else {
            throw MuSig2AccountError.invalidDescriptor("the musig tweak chain does not reach the output key")
        }
        return MuSig2Context(choice: choice, index: index, participants: sorted, aggregate: aggregate,
                             internalKey: internalKey, tweaks: tweaks, isXOnlyTweaks: isXOnly, signingKey: signingKey)
    }

    /// The message participants sign: the BIP341 key-path sighash. A
    /// participant never signs a sighash type that leaves outputs open.
    public func keyPathSighash(_ psbt: PSBT, input: Int) throws -> Data {
        let rawType = psbt.inputs[input].sighashType ?? 0
        guard rawType <= UInt32(UInt8.max) else { throw PSBTError.malformed("sighash type \(rawType)") }
        let hashType = SighashBIP341.HashType(rawValue: UInt8(rawType))
        guard hashType.commitsToAllOutputs else {
            throw PSBTError.malformed("refusing non-DEFAULT/ALL sighash type \(rawType)")
        }
        return try SighashBIP341.sighash(tx: psbt.unsignedTransaction(), inputIndex: input,
                                         spentOutputs: psbt.spentOutputs(), hashType: hashType)
    }

    /// The input's coordinates, from the known coin it spends.
    func coin(for psbt: PSBT, input: Int, knownUTXOs: [WalletUTXO]) throws -> WalletUTXO {
        guard psbt.inputs.indices.contains(input), let txid = psbt.inputs[input].previousTxid,
              let vout = psbt.inputs[input].outputIndex,
              let known = knownUTXOs.first(where: { $0.outpoint == Transaction.Outpoint(txid: txid, vout: vout) })
        else { throw MuSig2AccountError.invalidSpend("input \(input + 1) is not an available coin of this account") }
        return known
    }

    /// Round 1 for every input: reviews the spend, then attaches this
    /// device's BIP373 public nonce per input. Returns the secret nonces by
    /// input; the caller keeps them in memory for round 2 only and never
    /// reuses them.
    public func attachNonces(_ psbt: inout PSBT, signingKey key: HDKey, knownUTXOs: [WalletUTXO],
                             ownedOutputCoordinates: [OutputCoordinate], chainTip: UInt32,
                             rand: Data? = nil) throws -> [Int: [Data: Data]] {
        _ = try reviewSpend(psbt, knownUTXOs: knownUTXOs, ownedOutputCoordinates: ownedOutputCoordinates,
                            chainTip: chainTip)
        var secretNonces: [Int: [Data: Data]] = [:]
        for input in psbt.inputs.indices {
            let utxo = try coin(for: psbt, input: input, knownUTXOs: knownUTXOs)
            let context = try muSig2Context(choice: utxo.chain.rawValue, index: utxo.index)
            let message = try keyPathSighash(psbt, input: input)
            for (participant, secret) in try participantSecrets(context: context, key: key) {
                let (secretNonce, publicNonce) = try MuSig.nonceGenerate(
                    secretKey: secret, publicKey: participant, aggregateKey: context.outputKey,
                    message: message, rand: rand)
                try psbt.attachMuSig2PubNonce(input: input,
                                              id: PSBT.MuSig2KeyID(participant: participant, aggregate: context.signingKey),
                                              nonce: publicNonce)
                secretNonces[input, default: [:]][participant] = secretNonce
            }
            guard secretNonces[input] != nil else { throw MuSig2AccountError.noParticipantKey(input: input) }
        }
        return secretNonces
    }

    /// Round 2 for every input, once every participant attached a nonce:
    /// reviews the spend again, then partial-signs, consuming (zeroing) the
    /// secret nonces.
    public func sign(_ psbt: inout PSBT, signingKey key: HDKey, secretNonces: inout [Int: [Data: Data]],
                     knownUTXOs: [WalletUTXO], ownedOutputCoordinates: [OutputCoordinate], chainTip: UInt32) throws {
        _ = try reviewSpend(psbt, knownUTXOs: knownUTXOs, ownedOutputCoordinates: ownedOutputCoordinates,
                            chainTip: chainTip)
        for input in psbt.inputs.indices {
            let utxo = try coin(for: psbt, input: input, knownUTXOs: knownUTXOs)
            let context = try muSig2Context(choice: utxo.chain.rawValue, index: utxo.index)
            let session = try psbt.muSig2Session(input: input, aggregateKey: context.aggregate, tweaks: context.tweaks,
                                                 isXOnlyTweaks: context.isXOnlyTweaks,
                                                 message: keyPathSighash(psbt, input: input))
            let held = try participantSecrets(context: context, key: key)
            guard !held.isEmpty else { throw MuSig2AccountError.noParticipantKey(input: input) }
            var signed = 0
            for (participant, secret) in held {
                guard var secretNonce = secretNonces[input]?[participant] else { continue }
                defer { secretNonces[input]?[participant] = secretNonce }
                try psbt.signMuSig2(input: input,
                                    id: PSBT.MuSig2KeyID(participant: participant, aggregate: context.signingKey),
                                    secretNonce: &secretNonce, secretKey: secret, session: session)
                signed += 1
            }
            guard signed > 0 else { throw MuSig2AccountError.missingNonce(input: input) }
        }
    }

    /// Combines every input's partial signatures into its key-path signature.
    public func aggregate(_ psbt: inout PSBT, knownUTXOs: [WalletUTXO],
                          ownedOutputCoordinates: [OutputCoordinate], chainTip: UInt32) throws {
        _ = try reviewSpend(psbt, knownUTXOs: knownUTXOs, ownedOutputCoordinates: ownedOutputCoordinates,
                            chainTip: chainTip)
        for input in psbt.inputs.indices {
            let utxo = try coin(for: psbt, input: input, knownUTXOs: knownUTXOs)
            let context = try muSig2Context(choice: utxo.chain.rawValue, index: utxo.index)
            let session = try psbt.muSig2Session(input: input, aggregateKey: context.aggregate, tweaks: context.tweaks,
                                                 isXOnlyTweaks: context.isXOnlyTweaks,
                                                 message: keyPathSighash(psbt, input: input))
            try psbt.aggregateMuSig2(input: input, session: session)
        }
    }

    /// Finalizes the fully-signed PSBT and extracts the raw transaction.
    public func finalizeSpend(_ psbt: inout PSBT, knownUTXOs: [WalletUTXO],
                              ownedOutputCoordinates: [OutputCoordinate], chainTip: UInt32) throws -> Transaction {
        _ = try reviewSpend(psbt, knownUTXOs: knownUTXOs, ownedOutputCoordinates: ownedOutputCoordinates,
                            chainTip: chainTip)
        try psbt.finalize()
        let transaction = try psbt.extractedTransaction()
        try Wallet.checkStandardSize(transaction)
        return transaction
    }

    // MARK: - Participant secrets

    /// (participant compressed key, secret) for every participant `key` holds.
    private func participantSecrets(context: MuSig2Context, key: HDKey) throws -> [(Data, Data)] {
        var result: [(Data, Data)] = []
        for single in participants {
            guard let secret = try Self.secret(for: single, from: key),
                  let participant = try? Secp256k1.PrivateKey(secret).publicKey.compressed,
                  context.participants.contains(participant) else { continue }
            result.append((participant, secret))
        }
        return result
    }

    /// The participant's secret when `key` is its account key itself (an
    /// account-key wallet) or the master its origin descends from; nil
    /// otherwise. Participants carry no suffix, so the account key is the
    /// signing key at every coordinate.
    static func secret(for single: Descriptor.SingleKey, from key: HDKey) throws -> Data? {
        guard case let .extended(base, _) = single.base, key.privateKey != nil else { return nil }
        if key.publicKey == base.publicKey { return key.privateKey }
        guard let origin = single.origin, origin.fingerprint == key.fingerprint else { return nil }
        var derived = key
        for step in origin.path { derived = try derived.child(at: step) }
        return derived.publicKey == base.publicKey ? derived.privateKey : nil
    }
}
