import Foundation
import NativeSecp256k1

public enum MultisigAccountError: Error, Equatable {
    /// Not a supported account shape: `tr(NUMS, sortedmulti_a(k, …))`.
    case invalidDescriptor(String)
    /// A coin's scriptPubKey does not match the descriptor at its coordinates.
    case scriptMismatch(index: UInt32, choice: Int)
    /// No signer key for this input derives from the loaded key.
    case noSignerKey(input: Int)
    /// An imported spend is not an exact, safe spend of known account coins.
    case invalidSpend(String)
}

extension MultisigAccountError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        // `reason` is interpolated, so it is always a developer-written
        // literal describing the shape that failed: never user input, and
        // never part of the descriptor, which can carry key material.
        case let .invalidDescriptor(reason): "The multisig descriptor is invalid: \(reason)."
        case let .scriptMismatch(index, choice):
            "Multisig key \(choice)/\(index) does not produce the stored Bitcoin output."
        case let .noSignerKey(input): "This device holds no signer key for input \(input + 1)."
        case let .invalidSpend(reason): "This multisig spend is unsafe: \(reason)."
        }
    }
}

/// One stored multisig account: the descriptor, its address frontiers and
/// the coins the wallet's filter scan found for it. Spent coins stay as
/// tombstones so a reorg can restore them. The JSON keys match the vault
/// records of the shared-account Winnow, so its backups of script-path
/// accounts restore here.
public struct MultisigAccountRecord: Codable, Equatable, Identifiable, Sendable {
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

/// A raw k-of-n Taproot script-path account:
/// `tr(NUMS, sortedmulti_a(k, XPUB/<0;1>/*, …))` (BIP386, BIP387). The
/// internal key is the BIP341 "nothing up my sleeve" point, so the
/// `multi_a` leaf is the only way to spend: any k of the n signers. Each
/// signer makes an ordinary BIP340 signature over the script-path sighash,
/// with no rounds and no nonce state. Spends travel as PSBT text with the
/// BIP371 leaf, origin and signature fields: the creator builds the PSBT,
/// signers add signatures in any order, and once k verify the finalizer
/// assembles the BIP387 witness.
public struct MultisigAccount: Sendable {
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
    /// Signatures a spend needs.
    public let threshold: Int
    /// The signers in descriptor order.
    public let signers: [Descriptor.SingleKey]
    /// Whether the leaf is `sortedmulti_a` (keys sorted in the script).
    public let isSorted: Bool

    /// The only signer suffix accepted. Fixed templates are what make signer
    /// independence provable: `K/<0;1>/*` and `K/0/1` differ at (0, 0) and
    /// collide at (1, 0), so comparing keys at one coordinate is not a proof
    /// unless every signer carries the identical suffix (SEC-019).
    static let signerSuffix: [Descriptor.Derivation.Element] = [.multipath([0, 1]), .wildcard(hardened: false)]

    public init(descriptor: Descriptor, network: BitcoinNetwork) throws {
        guard case let .trTree(internalKey, tree) = descriptor.expression else {
            throw MultisigAccountError.invalidDescriptor("expected tr(NUMS, sortedmulti_a(k, …))")
        }
        let threshold: Int
        let signers: [Descriptor.SingleKey]
        let sorted: Bool
        switch tree {
        case let .leaf(.sortedMultiA(k, keys)): (threshold, signers, sorted) = (k, keys, true)
        case let .leaf(.multiA(k, keys)): (threshold, signers, sorted) = (k, keys, false)
        default:
            throw MultisigAccountError.invalidDescriptor("a multisig account has exactly one multi_a leaf")
        }
        // SEC-020: with a real internal key, whoever holds it spends alone,
        // whatever the threshold says.
        guard internalKey.derivation.elements.isEmpty, internalKey.origin == nil,
              case let .publicKey(raw) = internalKey.base,
              (raw.count == 32 ? raw : Data(raw.dropFirst())) == Taproot.unspendableInternalKey else {
            throw MultisigAccountError.invalidDescriptor(
                "the internal key can spend on its own, which would bypass the signers it lists")
        }
        guard signers.count >= 2 else {
            throw MultisigAccountError.invalidDescriptor("a multisig account needs at least two signers")
        }
        guard (1 ... signers.count).contains(threshold) else {
            throw MultisigAccountError.invalidDescriptor("the threshold must be between one and the number of signers")
        }
        for signer in signers {
            try Self.requireAccountKey(signer, network: network)
        }
        self.descriptor = descriptor
        self.network = network
        self.threshold = threshold
        self.signers = signers
        isSorted = sorted
        try requireDistinctSigners()
    }

    public init(_ string: String, network: BitcoinNetwork) throws {
        try self.init(descriptor: Descriptor(string), network: network)
    }

    /// The canonical account descriptor: `tr(NUMS, sortedmulti_a(k, …))`
    /// over the given signer key expressions (`[fp/86'/1'/0']xpub…/<0;1>/*`),
    /// validated as an account for `network`.
    public static func descriptor(threshold: Int, signers: [String], network: BitcoinNetwork) throws -> Descriptor {
        let text = "tr(\(Taproot.unspendableInternalKey.hex),sortedmulti_a(\(threshold),\(signers.joined(separator: ","))))"
        let descriptor: Descriptor
        do {
            descriptor = try Descriptor(text)
        } catch {
            throw MultisigAccountError.invalidDescriptor("a signer key expression does not parse")
        }
        _ = try MultisigAccount(descriptor: descriptor, network: network)
        return descriptor
    }

    /// The account's stable identifier: the descriptor's BIP380 checksum.
    public var id: String { String(descriptor.serialized().suffix(8)) }

    static func hdNetwork(for network: BitcoinNetwork) -> HDKey.Network {
        network == .mainnet ? .mainnet : .testnet
    }

    /// A signer as accepted here: an extended public key with its origin, on
    /// this network, under the fixed `/<0;1>/*` suffix. The origin must
    /// describe the key supplied: as many steps as the key is deep, ending at
    /// the key's own child index.
    private static func requireAccountKey(_ single: Descriptor.SingleKey, network: BitcoinNetwork) throws {
        guard case let .extended(key, keyNetwork) = single.base, key.privateKey == nil,
              let origin = single.origin else {
            throw MultisigAccountError.invalidDescriptor("every signer must be an extended public key carrying its origin")
        }
        guard origin.path.count == Int(key.depth), key.depth == 0 || origin.path.last == key.childIndex else {
            throw MultisigAccountError.invalidDescriptor("a signer's origin path does not match its key")
        }
        guard keyNetwork == hdNetwork(for: network) else {
            throw MultisigAccountError.invalidDescriptor("a signer's extended key belongs to a different network")
        }
        guard single.derivation.elements == signerSuffix else {
            throw MultisigAccountError.invalidDescriptor(
                "every signer must use the /<0;1>/* suffix, so the signers can be shown to be independent")
        }
    }

    /// A k-of-n account is only k-of-n if its signers are n distinct keys
    /// (SEC-009): a repeated signer needs fewer independent signers than the
    /// policy advertises. Account keys are compared as key material, so
    /// relabelling an origin cannot disguise a repeat; with one suffix
    /// template for everyone, distinct account keys never collide below.
    private func requireDistinctSigners() throws {
        var seen: Set<Data> = []
        for signer in signers {
            guard case let .extended(key, _) = signer.base, seen.insert(key.publicKey).inserted else {
                throw MultisigAccountError.invalidDescriptor(
                    "the same signing key appears more than once, so this account needs fewer signers than it claims")
            }
        }
    }

    /// Whether one signer is this account public key, whatever origin label
    /// the descriptor gives it.
    public func includes(accountKey: HDKey) -> Bool {
        signers.contains { signer in
            guard case let .extended(base, _) = signer.base else { return false }
            return base.publicKey == accountKey.publicKey
        }
    }

    /// Whether `key` (a master or BIP86 account key) holds one signer.
    public func hasSigner(for key: HDKey) -> Bool {
        signers.contains { (try? Self.accountSecretKey(for: $0, from: key)) != nil }
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

    /// The leaf script, its control block and the internal key at
    /// (choice, index), from the descriptor alone.
    struct Leaf {
        var internalKey: Data
        var version: UInt8
        var script: Script
        var controlBlock: Taproot.ControlBlock
    }

    func leaf(choice: Int, index: UInt32) throws -> Leaf {
        let (internalKey, tree) = try descriptor.resolvedTaproot(index: index, choice: choice)
        guard case let .leaf(version, script) = tree else {
            throw MultisigAccountError.invalidDescriptor("a multisig account has exactly one leaf")
        }
        let controlBlock = try Taproot.controlBlock(internalKey: internalKey, tree: tree, leafIndex: 0)
        return Leaf(internalKey: internalKey, version: version, script: script, controlBlock: controlBlock)
    }

    // MARK: - Review

    /// Validates a PSBT before it is shown, signed, finalized or broadcast:
    /// every input is a unique known coin of this account with the exact
    /// amount and script the sighash commits to and this account's own leaf
    /// and internal key; every signature commits to all outputs; amounts are
    /// valid; the fee is at most 10% of the inputs. Output ownership comes
    /// only from matching scripts against caller-supplied coordinates, never
    /// from PSBT metadata (SEC-004).
    public func reviewSpend(_ psbt: PSBT, knownUTXOs: [WalletUTXO],
                            ownedOutputCoordinates: [OutputCoordinate],
                            chainTip: UInt32) throws -> SpendReview {
        guard !psbt.inputs.isEmpty else { throw MultisigAccountError.invalidSpend("it has no inputs") }
        guard !psbt.outputs.isEmpty, psbt.outputs.count <= 1_000 else {
            throw MultisigAccountError.invalidSpend("it has no outputs or more than 1,000")
        }
        guard psbt.txVersion == 1 || psbt.txVersion == 2 else {
            throw MultisigAccountError.invalidSpend("transaction version \(psbt.txVersion) is not supported")
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
            throw MultisigAccountError.invalidSpend("the \(fee)-sat fee exceeds the 10% safety limit for these inputs")
        }
    }

    private func reviewedInputTotal(of psbt: PSBT, knownUTXOs: [WalletUTXO], chainTip: UInt32) throws -> Int64 {
        var seen: Set<Transaction.Outpoint> = []
        var total: Int64 = 0
        for (inputIndex, input) in psbt.inputs.enumerated() {
            guard let txid = input.previousTxid, txid.count == 32, let vout = input.outputIndex else {
                throw MultisigAccountError.invalidSpend("input \(inputIndex + 1) has no complete outpoint")
            }
            let outpoint = Transaction.Outpoint(txid: txid, vout: vout)
            guard seen.insert(outpoint).inserted else {
                throw MultisigAccountError.invalidSpend("input \(inputIndex + 1) repeats an earlier outpoint")
            }
            guard let known = knownUTXOs.first(where: { $0.outpoint == outpoint }) else {
                throw MultisigAccountError.invalidSpend("input \(inputIndex + 1) is not an available coin of this account")
            }
            try checkInput(input, inputIndex: inputIndex, utxo: known, chainTip: chainTip)
            let (sum, overflow) = total.addingReportingOverflow(known.amount)
            guard !overflow, sum <= Self.maxMoney else {
                throw MultisigAccountError.invalidSpend("input amounts exceed Bitcoin's supply")
            }
            total = sum
        }
        return total
    }

    private func checkInput(_ input: PSBT.Input, inputIndex: Int, utxo known: WalletUTXO, chainTip: UInt32) throws {
        guard known.amount > 0, known.amount <= Self.maxMoney,
              let claimed = input.witnessUTXO, claimed == known.spentOutput else {
            throw MultisigAccountError.invalidSpend("input \(inputIndex + 1) has the wrong amount or locking script")
        }
        if known.isCoinbase {
            let matureAt = known.height + Wallet.coinbaseMaturity - 1
            guard chainTip >= matureAt else {
                throw MultisigAccountError.invalidSpend(
                    "input \(inputIndex + 1) spends a coinbase that matures in \(matureAt - chainTip) blocks")
            }
        }
        guard try scriptPubKey(index: known.index, choice: known.chain.rawValue) == known.scriptPubKey else {
            throw MultisigAccountError.invalidSpend("input \(inputIndex + 1) does not belong to this descriptor")
        }
        let rawSighash = input.sighashType ?? 0
        guard rawSighash == 0 || rawSighash == 1 else {
            throw MultisigAccountError.invalidSpend("input \(inputIndex + 1) does not commit to every output")
        }
        let expected = try leaf(choice: known.chain.rawValue, index: known.index)
        let expectedLeaf = PSBT.TapLeafScript(controlBlock: expected.controlBlock, script: expected.script.bytes,
                                              leafVersion: expected.version)
        guard input.tapInternalKey == expected.internalKey, input.tapLeafScripts == [expectedLeaf] else {
            throw MultisigAccountError.invalidSpend("input \(inputIndex + 1) changes the spending policy")
        }
    }

    private func reviewedOutputs(of psbt: PSBT, inputTotal: Int64, ownedOutputCoordinates: [OutputCoordinate])
        throws -> (reviewed: [SpendReview.Output], total: Int64) {
        let candidates = Array(Set(ownedOutputCoordinates.filter { (0 ... 1).contains($0.choice) }))
        guard candidates.count <= 1_024 else {
            throw MultisigAccountError.invalidSpend("too many candidate account output paths")
        }
        let owned = Set(try candidates.map { try scriptPubKey(index: $0.index, choice: $0.choice) })
        var total: Int64 = 0
        var reviewed: [SpendReview.Output] = []
        for (outputIndex, output) in psbt.outputs.enumerated() {
            guard let amount = output.amount, amount > 0, amount <= Self.maxMoney,
                  let script = output.script, !script.isEmpty else {
                throw MultisigAccountError.invalidSpend("output \(outputIndex + 1) has an invalid amount or script")
            }
            let (sum, overflow) = total.addingReportingOverflow(amount)
            guard !overflow, sum <= Self.maxMoney else {
                throw MultisigAccountError.invalidSpend("output amounts exceed Bitcoin's supply")
            }
            total = sum
            reviewed.append(SpendReview.Output(amount: amount, scriptPubKey: script, isAccountOwned: owned.contains(script)))
        }
        guard total <= inputTotal else { throw MultisigAccountError.invalidSpend("outputs exceed its known inputs") }
        return (reviewed, total)
    }

    // MARK: - Creating a spend

    /// Builds the unsigned spend PSBT: coin selection sized for the BIP387
    /// witness, the transaction with an anti-fee-sniping locktime, the BIP371
    /// leaf and per-signer origins on every input, and the internal key, tap
    /// tree and signer origins on the change output.
    public func createSpend(utxos: [WalletUTXO], payments: [Payment], changeIndex: UInt32,
                            feeRateSatPerVByte: Double, chainTip: UInt32,
                            randomness: @Sendable () -> Double = { Double.random(in: 0 ..< 1) }) throws -> PSBT {
        for utxo in utxos {
            guard try scriptPubKey(index: utxo.index, choice: utxo.chain.rawValue) == utxo.scriptPubKey else {
                throw MultisigAccountError.scriptMismatch(index: utxo.index, choice: utxo.chain.rawValue)
            }
        }
        let changeScript = try scriptPubKey(index: changeIndex, choice: AddressChain.change.rawValue)
        let selection = try CoinSelection.select(utxos: utxos, payments: payments, changeScriptPubKey: changeScript,
                                                 feeRateSatPerVByte: feeRateSatPerVByte,
                                                 witnessBytesPerInput: try witnessBytesPerInput())
        try Self.checkFeeCeiling(fee: selection.fee, inputTotal: selection.selected.reduce(0) { $0 + $1.amount })
        let change = selection.changeAmount.map { Payment(amount: $0, scriptPubKey: changeScript) }
        let tx = try TransactionBuilder.build(
            inputs: selection.selected.map(\.outpoint), payments: payments, change: change,
            locktime: TransactionBuilder.antiFeeSnipingLocktime(tip: chainTip, randomness: randomness))
        var psbt = try PSBT(unsignedTx: tx,
                            inputs: selection.selected.map { PSBT.InputInfo(spentOutput: $0.spentOutput) },
                            outputs: tx.outputs.map { _ in PSBT.OutputInfo() })
        for (inputIndex, utxo) in selection.selected.enumerated() {
            let leaf = try leaf(choice: utxo.chain.rawValue, index: utxo.index)
            try psbt.attachScriptPath(input: inputIndex, controlBlock: leaf.controlBlock, leafScript: leaf.script,
                                      leafVersion: leaf.version,
                                      keyOrigins: keyOrigins(choice: utxo.chain.rawValue, index: utxo.index,
                                                             leafHashes: []))
        }
        if let change {
            let leaf = try leaf(choice: AddressChain.change.rawValue, index: changeIndex)
            let leafHash = Taproot.leafHash(version: leaf.version, script: leaf.script)
            for (outputIndex, output) in tx.outputs.enumerated()
            where output.scriptPubKey == change.scriptPubKey && output.value == change.amount {
                psbt.outputs[outputIndex].tapInternalKey = leaf.internalKey
                psbt.outputs[outputIndex].tapTree = [(depth: 0, leafVersion: leaf.version, script: leaf.script.bytes)]
                psbt.outputs[outputIndex].tapBIP32Derivation = try keyOrigins(
                    choice: AddressChain.change.rawValue, index: changeIndex, leafHashes: [leafHash])
            }
        }
        return psbt
    }

    /// Per-input witness bytes for fee estimation, exact for this account's
    /// spend: item count, one 64-byte signature or empty placeholder per
    /// signer slot (counted as signatures, the worst case), the leaf script
    /// and the 33-byte single-leaf control block, each length-prefixed.
    func witnessBytesPerInput() throws -> Int {
        let scriptSize = try leaf(choice: 0, index: 0).script.bytes.count
        return 1 + signers.count * 65 + Self.compactSizeLength(scriptSize) + scriptSize + 1 + 33
    }

    private static func compactSizeLength(_ value: Int) -> Int {
        value < 0xFD ? 1 : (value <= 0xFFFF ? 3 : 5)
    }

    /// BIP371 key origins for every signer at (choice, index): master
    /// fingerprint, the full path (origin path plus the suffix steps taken at
    /// (choice, index)) and the leaf hashes the key signs for.
    private func keyOrigins(choice: Int, index: UInt32, leafHashes: [Data]) throws -> [Data: PSBT.KeyOrigin] {
        var origins: [Data: PSBT.KeyOrigin] = [:]
        for signer in signers {
            guard let origin = signer.origin else { continue }
            let compressed = try descriptor.publicKey(of: signer, index: index, choice: choice)
            origins[Data(compressed.dropFirst())] = PSBT.KeyOrigin(
                leafHashes: leafHashes, masterFingerprint: origin.fingerprint,
                path: origin.path + [UInt32(choice), index])
        }
        return origins
    }

    // MARK: - Signing

    /// Reviews the spend, then adds a script-path signature to every input
    /// for each signer `key` holds (a master or the BIP86 account key itself).
    /// Throws `noSignerKey` when an input has no signer this key can sign for.
    public func sign(_ psbt: inout PSBT, signingKey key: HDKey, knownUTXOs: [WalletUTXO],
                     ownedOutputCoordinates: [OutputCoordinate], chainTip: UInt32) throws {
        _ = try reviewSpend(psbt, knownUTXOs: knownUTXOs, ownedOutputCoordinates: ownedOutputCoordinates,
                            chainTip: chainTip)
        var signed = psbt
        for input in signed.inputs.indices {
            let utxo = try coin(for: signed, input: input, knownUTXOs: knownUTXOs)
            var secrets: [Data] = []
            for signer in signers {
                guard let account = try Self.accountSecretKey(for: signer, from: key) else { continue }
                let child = try account.child(at: UInt32(utxo.chain.rawValue)).child(at: utxo.index)
                guard let secret = child.privateKey else { continue }
                secrets.append(secret)
            }
            guard !secrets.isEmpty else { throw MultisigAccountError.noSignerKey(input: input) }
            try signed.signScriptPath(input: input, privateKeys: secrets)
        }
        psbt = signed
    }

    /// Which signers (by position) have a verified signature on every input,
    /// judged by BIP340 verification against the recomputed sighash, never by
    /// the presence of an entry or any label in the PSBT.
    public func approvals(of psbt: PSBT, knownUTXOs: [WalletUTXO]) throws -> Set<Int> {
        let tx = try psbt.unsignedTransaction()
        let spentOutputs = try psbt.spentOutputs()
        var approved: Set<Int>?
        for input in psbt.inputs.indices {
            let utxo = try coin(for: psbt, input: input, knownUTXOs: knownUTXOs)
            let verified = try psbt.verifiedScriptPathSigners(input: input, tx: tx, spentOutputs: spentOutputs)
            var here: Set<Int> = []
            for (position, signer) in signers.enumerated() {
                let key = try descriptor.publicKey(of: signer, index: utxo.index, choice: utxo.chain.rawValue)
                if verified.contains(Data(key.dropFirst())) { here.insert(position) }
            }
            approved = approved.map { $0.intersection(here) } ?? here
        }
        return approved ?? []
    }

    /// Finalizes a PSBT with at least `threshold` verified signatures per
    /// input and extracts the raw transaction, after one more review.
    public func finalizeSpend(_ psbt: inout PSBT, knownUTXOs: [WalletUTXO],
                              ownedOutputCoordinates: [OutputCoordinate], chainTip: UInt32) throws -> Transaction {
        _ = try reviewSpend(psbt, knownUTXOs: knownUTXOs, ownedOutputCoordinates: ownedOutputCoordinates,
                            chainTip: chainTip)
        var finalized = psbt
        try finalized.finalize()
        let transaction = try finalized.extractedTransaction()
        try Wallet.checkStandardSize(transaction)
        psbt = finalized
        return transaction
    }

    /// The input's coordinates, from the known coin it spends.
    private func coin(for psbt: PSBT, input: Int, knownUTXOs: [WalletUTXO]) throws -> WalletUTXO {
        guard psbt.inputs.indices.contains(input), let txid = psbt.inputs[input].previousTxid,
              let vout = psbt.inputs[input].outputIndex,
              let known = knownUTXOs.first(where: { $0.outpoint == Transaction.Outpoint(txid: txid, vout: vout) })
        else { throw MultisigAccountError.invalidSpend("input \(input + 1) is not an available coin of this account") }
        return known
    }

    // MARK: - Signer secrets

    /// The signer's account key with its private half, when `key` is that
    /// account key itself (an account-key wallet) or the master its origin
    /// descends from; nil otherwise.
    static func accountSecretKey(for single: Descriptor.SingleKey, from key: HDKey) throws -> HDKey? {
        guard case let .extended(base, _) = single.base, key.privateKey != nil else { return nil }
        if key.publicKey == base.publicKey, key.chainCode == base.chainCode { return key }
        guard let origin = single.origin, origin.fingerprint == key.fingerprint else { return nil }
        var derived = key
        for step in origin.path { derived = try derived.child(at: step) }
        guard derived.publicKey == base.publicKey, derived.chainCode == base.chainCode else { return nil }
        return derived
    }
}
