import CryptoKit
import Foundation

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
    /// Present when a Ledger is one of the signers and has registered this
    /// account; absent in records written before Ledger support.
    public var ledger: LedgerRegistration?

    public init(id: String, name: String, descriptor: String, createdAtHeight: UInt32,
                nextReceiveIndex: UInt32 = 0, nextChangeIndex: UInt32 = 0,
                allUtxos: [WalletUTXO] = [], ledger: LedgerRegistration? = nil) {
        self.id = id
        self.name = name
        self.descriptor = descriptor
        self.createdAtHeight = createdAtHeight
        self.nextReceiveIndex = nextReceiveIndex
        self.nextChangeIndex = nextChangeIndex
        self.allUtxos = allUtxos
        self.ledger = ledger
    }

    public var utxos: [WalletUTXO] { allUtxos.filter { !$0.isSpent } }
    public var balance: Int64 { utxos.reduce(0) { $0 + $1.amount } }

    /// A stored Ledger registration must be this account's own policy and
    /// name one of its signers; anything else is refused with the record.
    public func checkLedgerRegistration(for account: MultisigAccount) throws {
        guard let ledger else { return }
        guard ledger.policyID.count == 32, ledger.hmac.count == 32,
              LedgerMultisig.ledgerSigner(of: account, fingerprint: ledger.masterFingerprint, path: ledger.keyPath) != nil,
              (try? LedgerWalletPolicy(name: ledger.policyName, account: account).id) == ledger.policyID else {
            throw MultisigAccountError.invalidDescriptor("the stored Ledger registration does not belong to this account")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, descriptor, createdAtHeight, nextReceiveIndex, nextChangeIndex, ledger
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
///
/// A nested account has several signers' leaves: its members are groups of
/// keys that always sign together (a phone and its Ledger, say), any
/// `threshold` of the members spend, and the tree holds one leaf per group
/// of that many members, each needing every key of those members. A key in
/// more than one leaf takes the next `/<2n;2n+1>/*` pair in each, the rule
/// the recovery leaf already followed, so no derived key is shared between
/// leaves (SEC-019) and BIP388 signers such as a Ledger can register the
/// whole tree. Spending reveals only the leaf that finished.
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
        /// `.recovery` when every input's sequence meets the recovery lock,
        /// so the recovery leaf can finish it as well as the signers' leaves.
        public var path: SpendPath = .signers
    }

    /// One leaf the account can spend on: the signers' leaf at a position
    /// among `signersLeaves` (`.signers` is the first, every ordinary
    /// account's only one), or the timelocked recovery leaf at a position
    /// among `recoveryLeaves` (`.recovery` is the first, every ordinary
    /// account's only one).
    public struct SpendPath: Hashable, Sendable, CustomStringConvertible {
        /// The position among the signers' leaves; nil for a recovery leaf.
        public let signersLeaf: Int?
        /// The position among the recovery leaves; nil for a signers' leaf.
        public let recoveryLeaf: Int?

        /// Any `threshold` of the first leaf's signers, at once.
        public static let signers = SpendPath(signersLeaf: 0, recoveryLeaf: nil)
        /// The first recovery leaf's keys, once each coin is `Recovery.blocks` old.
        public static let recovery = SpendPath(signersLeaf: nil, recoveryLeaf: 0)

        /// The signers' leaf at `leaf`.
        public static func signers(_ leaf: Int) -> SpendPath { SpendPath(signersLeaf: leaf, recoveryLeaf: nil) }
        /// The recovery leaf at `leaf`.
        public static func recovery(_ leaf: Int) -> SpendPath { SpendPath(signersLeaf: nil, recoveryLeaf: leaf) }

        public var isRecovery: Bool { signersLeaf == nil }

        public var description: String {
            if let signersLeaf { return "signers(\(signersLeaf))" }
            return recoveryLeaf == 0 ? "recovery" : "recovery(\(recoveryLeaf ?? 0))"
        }
    }

    /// One signers' leaf: `sortedmulti_a(threshold, keys…)`.
    public struct SignersLeaf: Equatable, Sendable {
        public var threshold: Int
        public var keys: [Descriptor.SingleKey]
        /// Whether the leaf is `sortedmulti_a` (keys sorted in the script).
        public var isSorted: Bool
    }

    /// A nested account read back from its leaves: `threshold` of `groups`
    /// spend, each group signing with `thresholds[i]` of its keys: all of
    /// them for a phone and its Ledger, 2 of 3 for a 2-of-3 account that is
    /// one member.
    public struct Members: Equatable, Sendable {
        public var threshold: Int
        public var groups: [[Descriptor.SingleKey]]
        /// How many of each group's keys sign for it, by position in `groups`.
        public var thresholds: [Int]

        /// The positions of the groups that need fewer than all their keys.
        public var thresholdGroups: [Int] { groups.indices.filter { thresholds[$0] < groups[$0].count } }
    }

    /// One member as the builder takes it: keys, `threshold` of which sign
    /// for the member. All of them by default (a phone and its Ledger); an
    /// account that is one member keeps its own threshold (2 of 3).
    public struct Member: Equatable, Sendable {
        public var keys: [String]
        public var threshold: Int

        public init(keys: [String], threshold: Int? = nil) {
            self.keys = keys
            self.threshold = threshold ?? keys.count
        }
    }

    /// A timelocked leaf, `and_v(v:pk(K),older(N))` or
    /// `and_v(v:multi_a(m,…),older(N))`: after a coin has not moved for N
    /// blocks, `threshold` of these keys may spend it without the signers.
    /// An ordinary account has at most one; a nested account whose recovery
    /// path is fewer of its members has one per group of them, needing every
    /// key it lists, all opening after the same N.
    public struct Recovery: Equatable, Sendable {
        public var threshold: Int
        public var keys: [Descriptor.SingleKey]
        /// BIP68 relative lock in blocks, 1...65535 (about 455 days).
        public var blocks: UInt32
    }

    /// How a new account's recovery path is chosen.
    public enum RecoveryPlan: Equatable, Sendable {
        /// After the delay, `threshold` of the same signers, each on its
        /// next derivation pair (`/<2;3>/*` in an ordinary account); for a
        /// nested account, `threshold` of its members, with a timelocked
        /// leaf per group of them.
        case fewerSigners(threshold: Int, blocks: UInt32)
        /// After the delay, `threshold` of these other keys (`…/<0;1>/*`).
        case separateKeys(threshold: Int, keys: [String], blocks: UInt32)
    }

    public let descriptor: Descriptor
    public let network: BitcoinNetwork
    /// The signers' leaves in tree order: one for an ordinary account.
    public let signersLeaves: [SignersLeaf]
    /// The timelocked recovery leaves in tree order, all opening after the
    /// same delay: none or one for an ordinary account.
    public let recoveryLeaves: [Recovery]
    /// Each leaf's path, in tree order.
    private let leafPaths: [SpendPath]

    /// The first recovery leaf, if the account has one. Every recovery leaf
    /// shares its delay, so it answers for the recovery path as a whole.
    public var recovery: Recovery? { recoveryLeaves.first }
    /// The recovery leaves' paths, in tree order.
    public var recoveryPaths: [SpendPath] { recoveryLeaves.indices.map { .recovery($0) } }

    /// Signatures a spend on the first signers' leaf needs.
    public var threshold: Int { signersLeaves[0].threshold }
    /// The distinct signer keys of the signers' leaves, in the order they
    /// first appear; an ordinary account's leaf, in descriptor order.
    public var signers: [Descriptor.SingleKey] {
        var seen: Set<Data> = []
        return signersLeaves.flatMap(\.keys).filter { seen.insert(Self.identity(of: $0)).inserted }
    }

    /// Whether the first leaf is `sortedmulti_a` (keys sorted in the script).
    public var isSorted: Bool { signersLeaves[0].isSorted }
    /// Whether the account has more than one signers' leaf.
    public var isNested: Bool { signersLeaves.count > 1 }
    /// The signers' leaves' paths, in tree order.
    public var signersPaths: [SpendPath] { signersLeaves.indices.map { .signers($0) } }

    /// The longest relative lock accepted: BIP68's 16-bit block count.
    public static let maximumRecoveryBlocks: UInt32 = 0xFFFF
    /// The most leaves an account may have, signers' and recovery leaves
    /// together. Every leaf travels in each PSBT input with its control
    /// block and key origins, so 32 three-key leaves put about 20 KB per
    /// input in a PSBT, and every address derives every leaf's keys. A
    /// Ledger takes fewer: its policy template is at most
    /// `LedgerWalletPolicy.maximumTemplateLength` characters, about ten
    /// three-key leaves. A 3-of-5 of 2-of-3 accounts (270 leaves) is refused.
    public static let maximumLeaves = 32
    /// A signer's key on its second path, for the recovery leaf of an
    /// ordinary account.
    static let recoverySuffix: [Descriptor.Derivation.Element] = pairSuffix(1)

    /// The only signer suffix accepted on a key's first appearance. Fixed
    /// templates are what make signer independence provable: `K/<0;1>/*`
    /// and `K/0/1` differ at (0, 0) and collide at (1, 0), so comparing keys
    /// at one coordinate is not a proof unless every signer carries the
    /// identical suffix (SEC-019).
    static let signerSuffix: [Descriptor.Derivation.Element] = pairSuffix(0)

    /// The suffix of a key's `n`th appearance (from 0): `/<2n;2n+1>/*`.
    static func pairSuffix(_ appearance: Int) -> [Descriptor.Derivation.Element] {
        [.multipath([UInt32(2 * appearance), UInt32(2 * appearance + 1)]), .wildcard(hardened: false)]
    }

    static func pairSuffixText(_ appearance: Int) -> String {
        "/<\(2 * appearance);\(2 * appearance + 1)>/*"
    }

    /// Which appearance a suffix is, or nil for any other derivation.
    static func appearance(of elements: [Descriptor.Derivation.Element]) -> Int? {
        guard elements.count == 2, case let .multipath(values) = elements[0], values.count == 2,
              case .wildcard(hardened: false) = elements[1], values[0] % 2 == 0, values[1] == values[0] + 1 else {
            return nil
        }
        return Int(values[0] / 2)
    }

    public init(descriptor: Descriptor, network: BitcoinNetwork) throws {
        guard case let .trTree(internalKey, tree) = descriptor.expression else {
            throw MultisigAccountError.invalidDescriptor("expected tr(NUMS, sortedmulti_a(k, …))")
        }
        let (signersLeaves, recoveryLeaves, paths) = try Self.leaves(of: tree)
        // SEC-020: with a real internal key, whoever holds it spends alone,
        // whatever the threshold says.
        guard Self.isUnspendable(internalKey, network: network) else {
            throw MultisigAccountError.invalidDescriptor(
                "the internal key can spend on its own, which would bypass the signers it lists")
        }
        var keys = try Self.admit(signersLeaves, network: network)
        self.descriptor = descriptor
        self.network = network
        self.signersLeaves = signersLeaves
        leafPaths = paths
        self.recoveryLeaves = try Self.recovery(from: recoveryLeaves, keys: &keys, network: network)
    }

    /// The tree's leaves in order: the signers' leaves, the timelocked
    /// recovery leaves, and each leaf's path.
    private static func leaves(of tree: Descriptor.ScriptTree) throws
        -> (signers: [SignersLeaf], recovery: [Descriptor.LeafExpression], paths: [SpendPath]) {
        var leaves: [Descriptor.LeafExpression] = []
        func collect(_ node: Descriptor.ScriptTree) {
            switch node {
            case let .leaf(leaf): leaves.append(leaf)
            case let .branch(left, right):
                collect(left)
                collect(right)
            }
        }
        collect(tree)
        var signersLeaves: [SignersLeaf] = []
        var recoveryLeaves: [Descriptor.LeafExpression] = []
        var paths: [SpendPath] = []
        for leaf in leaves {
            switch leaf {
            case let .sortedMultiA(k, keys):
                paths.append(.signers(signersLeaves.count))
                signersLeaves.append(SignersLeaf(threshold: k, keys: keys, isSorted: true))
            case let .multiA(k, keys):
                paths.append(.signers(signersLeaves.count))
                signersLeaves.append(SignersLeaf(threshold: k, keys: keys, isSorted: false))
            case .timelocked:
                paths.append(.recovery(recoveryLeaves.count))
                recoveryLeaves.append(leaf)
            case .pk:
                throw MultisigAccountError.invalidDescriptor(
                    "a multisig account has multi_a leaves, and timelocked recovery leaves beside them")
            }
        }
        guard !signersLeaves.isEmpty else {
            throw MultisigAccountError.invalidDescriptor("a multisig account has exactly one multi_a leaf")
        }
        guard leaves.count <= maximumLeaves else {
            throw MultisigAccountError.invalidDescriptor("a multisig account has at most \(maximumLeaves) leaves")
        }
        return (signersLeaves, recoveryLeaves, paths)
    }

    /// The keys' bookkeeping across the leaves: how often each appeared,
    /// and the origin it carried.
    private struct AdmittedKeys {
        var appearances: [Data: Int] = [:]
        var origins: [Data: Descriptor.KeyOrigin] = [:]
        /// Each signers' leaf's key set, so no group of signers appears twice.
        var groups: Set<Set<Data>> = []
        /// Each recovery leaf's key set, likewise.
        var recoveryGroups: Set<Set<Data>> = []
    }

    /// Every signers' leaf: at least two keys, a threshold within them,
    /// each key admitted on the pair its appearance calls for.
    private static func admit(_ leaves: [SignersLeaf], network: BitcoinNetwork) throws -> AdmittedKeys {
        var keys = AdmittedKeys()
        for leaf in leaves {
            guard leaf.keys.count >= 2 else {
                throw MultisigAccountError.invalidDescriptor("a multisig account needs at least two signers")
            }
            guard (1 ... leaf.keys.count).contains(leaf.threshold) else {
                throw MultisigAccountError.invalidDescriptor("the threshold must be between one and the number of signers")
            }
            var seen: Set<Data> = []
            for signer in leaf.keys {
                try admit(signer, nested: leaves.count > 1, network: network, keys: &keys, seen: &seen)
            }
            guard keys.groups.insert(seen).inserted else {
                throw MultisigAccountError.invalidDescriptor("the same group of signers appears in two leaves")
            }
        }
        return keys
    }

    /// One key of a signers' leaf. A k-of-n leaf is only k-of-n if its keys
    /// are n distinct keys (SEC-009): a repeated signer needs fewer
    /// independent signers than the policy advertises. Keys are compared as
    /// key material, so relabelling an origin cannot disguise a repeat; with
    /// one suffix template per appearance, distinct account keys never
    /// collide below. A key in several leaves keeps one origin.
    private static func admit(_ signer: Descriptor.SingleKey, nested: Bool, network: BitcoinNetwork,
                              keys: inout AdmittedKeys, seen: inout Set<Data>) throws {
        let identity = try requireAccountKey(signer, network: network,
                                             suffix: pairSuffix(keys.appearances[self.identity(of: signer), default: 0]),
                                             nested: nested)
        guard seen.insert(identity).inserted else {
            throw MultisigAccountError.invalidDescriptor(
                "the same signing key appears more than once, so this account needs fewer signers than it claims")
        }
        guard keys.origins[identity] == nil || keys.origins[identity] == signer.origin else {
            throw MultisigAccountError.invalidDescriptor(
                "a signer in more than one leaf must keep its own fingerprint and path in each")
        }
        keys.origins[identity] = signer.origin
        keys.appearances[identity, default: 0] += 1
    }

    /// The recovery leaves' rules: one timelock of 1...65535 blocks that
    /// every recovery leaf shares, distinct keys in each leaf and no key set
    /// twice, each key an origin-bearing public key of this network. A key
    /// that is also a signer appears with that signer's own origin on the
    /// pair after its last leaf, `/<2;3>/*` in an ordinary account; any
    /// other key on `/<0;1>/*` (SEC-019). No derived key is therefore
    /// shared between the leaves, which BIP388 signers such as a Ledger
    /// also require, and a signer finds its key in every leaf by the same
    /// fingerprint and path. Joining with a relabelled signer is refused in
    /// AppTests/MultisigAccountFlowTests.testBuilderMakesAccountWithAnotherWinnowAndRecovery;
    /// the other look-alikes are in TimelockedMultisigTests.admissionRefusals
    /// and NestedMultisigTests.admissionRefusals.
    private static func recovery(from leaves: [Descriptor.LeafExpression], keys: inout AdmittedKeys,
                                 network: BitcoinNetwork) throws -> [Recovery] {
        var recoveries: [Recovery] = []
        for leaf in leaves {
            guard case let .timelocked(condition, blocks) = leaf else {
                throw MultisigAccountError.invalidDescriptor("a leaf beside the signers' must be a timelocked recovery path")
            }
            guard (1 ... maximumRecoveryBlocks).contains(blocks) else {
                throw MultisigAccountError.invalidDescriptor("a recovery delay must be 1 to 65535 blocks")
            }
            guard recoveries.allSatisfy({ $0.blocks == blocks }) else {
                throw MultisigAccountError.invalidDescriptor("every recovery leaf must open after the same delay")
            }
            var seen: Set<Data> = []
            for key in condition.keys {
                try requireRecoveryKey(key, keys: &keys, seen: &seen, network: network)
            }
            guard keys.recoveryGroups.insert(seen).inserted else {
                throw MultisigAccountError.invalidDescriptor("the same group of recovery keys appears in two leaves")
            }
            recoveries.append(Recovery(threshold: condition.threshold, keys: condition.keys, blocks: blocks))
        }
        return recoveries
    }

    /// One recovery key: an extended key not seen before in the leaf; a
    /// signer's key carries that signer's origin and its next pair, any
    /// other key `/<0;1>/*`, then `/<2;3>/*` in a later recovery leaf.
    private static func requireRecoveryKey(_ key: Descriptor.SingleKey, keys: inout AdmittedKeys,
                                           seen: inout Set<Data>, network: BitcoinNetwork) throws {
        guard case let .extended(xpub, _) = key.base else {
            throw MultisigAccountError.invalidDescriptor("every recovery key must be an extended public key")
        }
        guard seen.insert(xpub.publicKey).inserted else {
            throw MultisigAccountError.invalidDescriptor("the same recovery key appears more than once")
        }
        let knownOrigin = keys.origins[xpub.publicKey]
        guard knownOrigin == nil || key.origin == knownOrigin else {
            throw MultisigAccountError.invalidDescriptor(
                "a signer reused for recovery must keep its own fingerprint and path there")
        }
        _ = try requireAccountKey(key, network: network, suffix: pairSuffix(keys.appearances[xpub.publicKey, default: 0]),
                                  recovery: true)
        keys.origins[xpub.publicKey] = key.origin
        keys.appearances[xpub.publicKey, default: 0] += 1
    }

    public init(_ string: String, network: BitcoinNetwork) throws {
        try self.init(descriptor: Descriptor(string), network: network)
    }

    /// The canonical account descriptor: `tr(NUMS, sortedmulti_a(k, …))`
    /// over the given signer key expressions (`[fp/86'/1'/0']xpub…/<0;1>/*`),
    /// validated as an account for `network`. The internal key is written as
    /// an extended key on the NUMS point (`unspendableKeyExpression`), so a
    /// BIP388 signer such as a Ledger can register the account.
    ///
    /// The signers, and a recovery leaf's separate keys, are written in one
    /// canonical order whatever order they arrive in: by x-only account key,
    /// ascending. The internal key's chain code hashes the keys in written
    /// order, so without it two people listing the same keys differently,
    /// or someone rebuilding an account from its keys, would get another
    /// account with other addresses. Accounts built before this keep their
    /// stored descriptor, which carries its own internal key. Order
    /// independence is in MultisigAccountTests.signerOrderDoesNotMatter and
    /// TimelockedMultisigTests.recoveryKeyOrderDoesNotMatter;
    /// `scripts/check-multisig-core` holds the addresses to Bitcoin Core.
    public static func descriptor(threshold: Int, signers: [String], recovery: RecoveryPlan? = nil,
                                  network: BitcoinNetwork) throws -> Descriptor {
        let signers = try canonicalOrder(signers)
        let leaf = "sortedmulti_a(\(threshold),\(signers.joined(separator: ",")))"
        var leaves = [leaf]
        if let recovery { leaves.append(try Self.recoveryLeaf(recovery, signers: signers)) }
        return try build(leaves: leaves, network: network)
    }

    /// A nested account whose members each sign with every key they have:
    /// `descriptor(members:threshold:recovery:network:)` over `Member`s.
    public static func descriptor(members: [[String]], threshold: Int, recovery: RecoveryPlan? = nil,
                                  network: BitcoinNetwork) throws -> Descriptor {
        try descriptor(members: members.map { Member(keys: $0) }, threshold: threshold, recovery: recovery,
                       network: network)
    }

    /// A nested account: `threshold` of `members` spend, each member a group
    /// of keys that sign together (a phone and its Ledger), or a threshold
    /// over its keys (a 2-of-3 account that is one member). One leaf per
    /// group of `threshold` members and per way the members of the group
    /// can meet their own thresholds: for a 2-of-3 member A and one-key
    /// members B and C, the pair A and B is three leaves, `(a1, a2, b)`,
    /// `(a1, a3, b)` and `(a2, a3, b)`, each needing every key it lists. A
    /// key in several leaves takes `/<2;3>/*`, `/<4;5>/*`… in turn, in tree
    /// order. Members are written in one canonical order, by their lowest
    /// key, the leaves in the order of the members and keys they take, so
    /// listing members or their keys differently gives the same descriptor.
    /// When every member is one key, this is the ordinary account. A
    /// recovery path of fewer members is a timelocked leaf per group of
    /// them, built the same way; separate keys are one leaf. At most
    /// `maximumLeaves` leaves in all.
    /// Checked against Bitcoin Core by `scripts/check-multisig-core`, and
    /// in NestedMultisigTests.
    public static func descriptor(members: [Member], threshold: Int, recovery: RecoveryPlan? = nil,
                                  network: BitcoinNetwork) throws -> Descriptor {
        try checkMembers(members, threshold: threshold)
        if members.allSatisfy({ $0.keys.count == 1 }) {
            return try descriptor(threshold: threshold, signers: members.map(\.keys[0]), recovery: recovery, network: network)
        }
        guard threshold > 1 || members.allSatisfy({ $0.threshold > 1 }) else {
            throw MultisigAccountError.invalidDescriptor(
                "a threshold of one member would let a single key spend alone; give every member two keys that sign, or raise it")
        }
        let ordered = try orderedMembers(members)
        try checkLeafCount(ordered, threshold: threshold, recovery: recovery)
        var appearances: [String: Int] = [:]
        var leaves = leafKeys(members: ordered, groupSize: threshold, appearances: &appearances).map { keys in
            "sortedmulti_a(\(keys.count),\(keys.joined(separator: ",")))"
        }
        switch recovery {
        case nil:
            break
        case let .separateKeys(m, keys, blocks):
            leaves.append(try recoveryLeaf(.separateKeys(threshold: m, keys: try canonicalOrder(keys), blocks: blocks),
                                           signers: []))
        case let .fewerSigners(m, blocks):
            guard (1 ... members.count).contains(m) else {
                throw MultisigAccountError.invalidDescriptor("the recovery threshold must be between one and the number of members")
            }
            leaves += try leafKeys(members: ordered, groupSize: m, appearances: &appearances).map {
                try timelockedLeaf(threshold: $0.count, keys: $0, blocks: blocks)
            }
        }
        return try build(leaves: leaves, network: network)
    }

    /// At least two members, each with a key and a threshold within its
    /// keys; a threshold within the members. A threshold of one member
    /// gives every member a leaf of its own, so each member must then need
    /// two keys, or one key would spend alone, which no multisig account
    /// has. A threshold of all the members, each signing with every key, is
    /// one leaf of every key: the ordinary account, written as such.
    private static func checkMembers(_ members: [Member], threshold: Int) throws {
        guard members.count >= 2, members.allSatisfy({ !$0.keys.isEmpty }) else {
            throw MultisigAccountError.invalidDescriptor("a nested account needs at least two members, each with a key")
        }
        guard members.allSatisfy({ (1 ... $0.keys.count).contains($0.threshold) }) else {
            throw MultisigAccountError.invalidDescriptor("a member's threshold must be between one and its number of keys")
        }
        guard (1 ... members.count).contains(threshold) else {
            throw MultisigAccountError.invalidDescriptor("the threshold must be between one and the number of members")
        }
    }

    /// A member with its keys bare of the `/<0;1>/*` suffix, in canonical
    /// order; members themselves ordered by their lowest key.
    private struct OrderedMember {
        var keys: [String]
        var threshold: Int
        /// How many ways its keys can meet its threshold.
        var choices: Int { MultisigAccount.combinations(of: Array(keys.indices), size: threshold).count }
    }

    private static func orderedMembers(_ members: [Member]) throws -> [OrderedMember] {
        let suffix = pairSuffixText(0)
        let ordered = try members.map { member -> (key: Data, member: OrderedMember) in
            let sorted = try canonicalOrder(member.keys)
            let bare = try sorted.map { expression -> String in
                guard expression.hasSuffix(suffix) else {
                    throw MultisigAccountError.invalidDescriptor(
                        "every signer must use the /<0;1>/* suffix, so the signers can be shown to be independent")
                }
                return String(expression.dropLast(suffix.count))
            }
            return (try accountKey(in: sorted[0]), OrderedMember(keys: bare, threshold: member.threshold))
        }.sorted { $0.key.lexicographicallyPrecedes($1.key) }.map(\.member)
        let keyCount = ordered.reduce(0) { $0 + $1.keys.count }
        guard Set(ordered.flatMap(\.keys)).count == keyCount else {
            throw MultisigAccountError.invalidDescriptor("the same signing key appears in two members")
        }
        return ordered
    }

    /// Refuses a tree of more than `maximumLeaves` leaves before any is
    /// written, naming the count.
    private static func checkLeafCount(_ members: [OrderedMember], threshold: Int, recovery: RecoveryPlan?) throws {
        var count = leafCount(members.map(\.choices), groupSize: threshold)
        switch recovery {
        case nil: break
        case .separateKeys: count += 1
        case let .fewerSigners(m, _): count += leafCount(members.map(\.choices), groupSize: min(m, members.count))
        }
        guard count <= maximumLeaves else {
            throw MultisigAccountError.invalidDescriptor(
                "these members would make \(count) leaves, and an account has at most \(maximumLeaves)")
        }
    }

    /// How many leaves every group of `groupSize` members makes when each
    /// member in a group has `choices[i]` ways to sign: the coefficient of
    /// x^groupSize in the product of (1 + choices[i]·x), saturating at
    /// `Int.max` so an absurd tree cannot overflow.
    static func leafCount(_ choices: [Int], groupSize: Int) -> Int {
        var coefficients = [1] + Array(repeating: 0, count: groupSize)
        for choice in choices {
            for degree in stride(from: groupSize, through: 1, by: -1) {
                let (term, overflow) = coefficients[degree - 1].multipliedReportingOverflow(by: choice)
                let (sum, carried) = coefficients[degree].addingReportingOverflow(term)
                coefficients[degree] = overflow || carried ? Int.max : sum
            }
        }
        return coefficients[groupSize]
    }

    /// The key lists of one leaf per group of `groupSize` members and per
    /// way the group's members meet their thresholds, in canonical order:
    /// groups in member order, a member's choices in key order, each leaf's
    /// keys sorted and each key on the pair its appearance so far calls
    /// for. `appearances` carries across the signers' and recovery leaves.
    private static func leafKeys(members: [OrderedMember], groupSize: Int,
                                 appearances: inout [String: Int]) -> [[String]] {
        var leaves: [[String]] = []
        for group in combinations(of: Array(members.indices), size: groupSize) {
            let choices = group.map { member in
                combinations(of: Array(members[member].keys.indices), size: members[member].threshold)
                    .map { $0.map { members[member].keys[$0] } }
            }
            for choice in product(choices) {
                let keys = choice.flatMap { $0 }.sorted { bareKey($0).lexicographicallyPrecedes(bareKey($1)) }
                leaves.append(keys.map { key in
                    defer { appearances[key, default: 0] += 1 }
                    return key + pairSuffixText(appearances[key, default: 0])
                })
            }
        }
        return leaves
    }

    /// The x-only account key of a bare key expression, for sorting; the
    /// expressions were parsed by `orderedMembers`, so this cannot fail.
    private static func bareKey(_ expression: String) -> Data {
        (try? accountKey(in: expression)) ?? Data()
    }

    /// Every way to take one element from each list, first list varying
    /// slowest.
    static func product<T>(_ lists: [[T]]) -> [[T]] {
        lists.reduce([[]]) { partial, list in partial.flatMap { prefix in list.map { prefix + [$0] } } }
    }

    /// The descriptor over leaves already in their final text and order:
    /// a balanced tree of them under the NUMS extended key, validated.
    private static func build(leaves: [String], network: BitcoinNetwork) throws -> Descriptor {
        let tree = nest(leaves)
        let descriptor: Descriptor
        do {
            let draft = try Descriptor("tr(\(Taproot.unspendableInternalKey.hex),\(tree))")
            let internalKey = try unspendableKeyExpression(leafKeys: Array(draft.allKeys.dropFirst()), network: network)
            descriptor = try Descriptor("tr(\(internalKey),\(tree))")
        } catch let error as MultisigAccountError {
            throw error
        } catch {
            throw MultisigAccountError.invalidDescriptor("a signer key expression does not parse")
        }
        _ = try MultisigAccount(descriptor: descriptor, network: network)
        return descriptor
    }

    /// `{{a,b},{c,d}}`: leaves paired from the left, halving at each level.
    private static func nest(_ leaves: [String]) -> String {
        guard leaves.count > 1 else { return leaves[0] }
        let half = (leaves.count + 1) / 2
        return "{\(nest(Array(leaves[..<half]))),\(nest(Array(leaves[half...])))}"
    }

    static func combinations(of values: [Int], size: Int) -> [[Int]] {
        guard size > 0 else { return [[]] }
        guard values.count >= size else { return [] }
        var result: [[Int]] = []
        for (offset, value) in values.enumerated() {
            for rest in combinations(of: Array(values[(offset + 1)...]), size: size - 1) {
                result.append([value] + rest)
            }
        }
        return result
    }

    /// Key expressions sorted by their x-only account key, ascending (the
    /// order `sortedmulti_a` gives its derived keys).
    private static func canonicalOrder(_ expressions: [String]) throws -> [String] {
        let keyed = try expressions.map { expression -> (key: Data, expression: String) in
            (try accountKey(in: expression), expression)
        }
        return keyed.sorted { $0.key.lexicographicallyPrecedes($1.key) }.map(\.expression)
    }

    /// The x-only account key of a key expression.
    private static func accountKey(in expression: String) throws -> Data {
        guard let parsed = try? Descriptor("tr(\(expression))"), case let .tr(single) = parsed.expression,
              case let .extended(xpub, _) = single.base else {
            throw MultisigAccountError.invalidDescriptor("a signer key expression does not parse")
        }
        return Data(xpub.publicKey.dropFirst())
    }

    /// The recovery leaf's text: `and_v(v:pk(K),older(N))` for one key,
    /// `and_v(v:multi_a(m,…),older(N))` for several. Reused signers move to
    /// their `/<2;3>/*` path.
    private static func recoveryLeaf(_ plan: RecoveryPlan, signers: [String]) throws -> String {
        let (threshold, keys, blocks): (Int, [String], UInt32)
        switch plan {
        case let .fewerSigners(m, n):
            let suffix = "/<0;1>/*"
            guard signers.allSatisfy({ $0.hasSuffix(suffix) }) else {
                throw MultisigAccountError.invalidDescriptor(
                    "every signer must use the /<0;1>/* suffix, so the signers can be shown to be independent")
            }
            (threshold, keys, blocks) = (m, signers.map { String($0.dropLast(suffix.count)) + "/<2;3>/*" }, n)
        case let .separateKeys(m, others, n):
            (threshold, keys, blocks) = (m, try canonicalOrder(others), n)
        }
        return try timelockedLeaf(threshold: threshold, keys: keys, blocks: blocks)
    }

    /// `and_v(v:pk(K),older(N))` for one key, `and_v(v:multi_a(m,…),older(N))`
    /// for several, the keys already on their paths.
    private static func timelockedLeaf(threshold: Int, keys: [String], blocks: UInt32) throws -> String {
        guard (1 ... maximumRecoveryBlocks).contains(blocks) else {
            throw MultisigAccountError.invalidDescriptor("a recovery delay must be 1 to 65535 blocks")
        }
        guard (1 ... keys.count).contains(threshold) else {
            throw MultisigAccountError.invalidDescriptor("the recovery threshold must be between one and its number of keys")
        }
        if keys.count == 1 { return "and_v(v:pk(\(keys[0])),older(\(blocks)))" }
        return "and_v(v:multi_a(\(threshold),\(keys.joined(separator: ","))),older(\(blocks)))"
    }

    /// BIP388 wallet policies, and so Ledger's Bitcoin app, admit only
    /// extended keys, never a bare public key. The internal key is therefore
    /// an xpub on BIP341's NUMS point H, built as Liana builds it: chain code
    /// SHA-256 of the leaf keys' compressed public keys in descriptor order,
    /// depth 0, no origin, the shared `/<0;1>/*` suffix. Every child is
    /// H + t·G for a public t, so no one knows its discrete logarithm.
    static func unspendableKeyExpression(leafKeys: [Descriptor.SingleKey], network: BitcoinNetwork) throws -> String {
        var concatenated = Data()
        for key in leafKeys {
            guard case let .extended(xpub, _) = key.base else {
                throw MultisigAccountError.invalidDescriptor("every signer must be an extended public key carrying its origin")
            }
            concatenated.append(xpub.publicKey)
        }
        let nums = HDKey(depth: 0, parentFingerprint: 0, childIndex: 0, chainCode: Data(SHA256.hash(data: concatenated)),
                         privateKey: nil, publicKey: Data([0x02]) + Taproot.unspendableInternalKey)
        return nums.serialized(network: hdNetwork(for: network)) + "/<0;1>/*"
    }

    /// SEC-020: the internal key must be one nobody can sign for. Two forms
    /// qualify: the bare NUMS key H (accounts made before Ledger support),
    /// and an xpub with no origin whose key is H under the signers' suffix,
    /// on this network. Any chain code is safe: children of H stay unknown
    /// logarithms. Anything else is a key someone may hold.
    static func isUnspendable(_ key: Descriptor.SingleKey, network: BitcoinNetwork) -> Bool {
        guard key.origin == nil else { return false }
        switch key.base {
        case let .publicKey(raw):
            return key.derivation.elements.isEmpty
                && (raw.count == 32 ? raw : Data(raw.dropFirst())) == Taproot.unspendableInternalKey
        case let .extended(xpub, keyNetwork):
            return xpub.privateKey == nil && keyNetwork == hdNetwork(for: network)
                && xpub.publicKey == Data([0x02]) + Taproot.unspendableInternalKey
                && key.derivation.elements == signerSuffix
        case .privateKey:
            return false
        }
    }

    /// The account's stable identifier: the descriptor's BIP380 checksum.
    public var id: String { String(descriptor.serialized().suffix(8)) }

    static func hdNetwork(for network: BitcoinNetwork) -> HDKey.Network {
        network == .mainnet ? .mainnet : .testnet
    }

    /// A key's identity for repeats and reuse: its compressed public key.
    static func identity(of key: Descriptor.SingleKey) -> Data {
        if case let .extended(xpub, _) = key.base { return xpub.publicKey }
        return Data()
    }

    /// A signer as accepted here: an extended public key with its origin, on
    /// this network, under the fixed suffix for this appearance. The origin
    /// must describe the key supplied: as many steps as the key is deep,
    /// ending at the key's own child index. Returns the key's identity.
    @discardableResult
    private static func requireAccountKey(_ single: Descriptor.SingleKey, network: BitcoinNetwork,
                                          suffix: [Descriptor.Derivation.Element] = signerSuffix,
                                          nested: Bool = false, recovery: Bool = false) throws -> Data {
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
        guard single.derivation.elements == suffix else {
            let pair = pairSuffixText(appearance(of: suffix) ?? 0)
            throw MultisigAccountError.invalidDescriptor(
                suffix == signerSuffix ? "every signer must use the /<0;1>/* suffix, so the signers can be shown to be independent"
                    : recovery ? "a signer reused for recovery must use its \(pair) path there"
                    : nested ? "a signer in more than one leaf must take its \(pair) path in the next"
                    : "a signer must not appear twice in one leaf")
        }
        return key.publicKey
    }

    /// A signer key expression as the builders take it and the app's signer
    /// roster keeps it: `[fp/path]xpub…/<0;1>/*`, an extended public key
    /// carrying its origin, on `network`. Exercised through the roster by
    /// AppTests/SignerRosterTests.
    public static func signerKey(_ expression: String, network: BitcoinNetwork) throws -> Descriptor.SingleKey {
        let text = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains(where: { $0 == "(" || $0 == ")" || $0 == "," || $0.isWhitespace }),
              let parsed = try? Descriptor("tr(\(text))"), case let .tr(single) = parsed.expression else {
            throw MultisigAccountError.invalidDescriptor("a signer key expression does not parse")
        }
        try requireAccountKey(single, network: network)
        return single
    }

    /// The signers' key expressions as the builders take them, each on the
    /// `/<0;1>/*` suffix whatever path its leaf gave it: what the app pastes
    /// to make a whole account one member of another.
    public var signerExpressions: [String] {
        signers.map { signer in
            var key = signer
            key.derivation = Descriptor.Derivation(Self.signerSuffix)
            return Serializer.serialize(key)
        }
    }

    /// Every key expression in the account: each signers' leaf's keys in
    /// tree order, then each recovery leaf's. A signer in several leaves is
    /// listed once per leaf, each time on that leaf's path.
    public var allKeys: [Descriptor.SingleKey] { signersLeaves.flatMap(\.keys) + recoveryLeaves.flatMap(\.keys) }

    /// The keys of `path`'s leaf, in descriptor order; none for a leaf the
    /// account does not have.
    public func keys(on path: SpendPath) -> [Descriptor.SingleKey] {
        if let leaf = path.signersLeaf { return signersLeaves.indices.contains(leaf) ? signersLeaves[leaf].keys : [] }
        guard let leaf = path.recoveryLeaf, recoveryLeaves.indices.contains(leaf) else { return [] }
        return recoveryLeaves[leaf].keys
    }

    /// How many of `path`'s keys must sign.
    public func threshold(on path: SpendPath) -> Int {
        if let leaf = path.signersLeaf { return signersLeaves.indices.contains(leaf) ? signersLeaves[leaf].threshold : 0 }
        guard let leaf = path.recoveryLeaf, recoveryLeaves.indices.contains(leaf) else { return 0 }
        return recoveryLeaves[leaf].threshold
    }

    /// The members of a nested account, read from its signers' leaves. Nil
    /// for an ordinary account, or a tree of another shape.
    public var members: Members? {
        guard isNested else { return nil }
        return Self.members(of: signersLeaves.map { ($0.threshold, $0.keys) })
    }

    /// The members a recovery path of fewer members reads back as, when the
    /// account has a timelocked leaf per group of them; nil for one leaf.
    public var recoveryMembers: Members? {
        guard recoveryLeaves.count > 1 else { return nil }
        return Self.members(of: recoveryLeaves.map { ($0.threshold, $0.keys) })
    }

    /// Members read from leaves that each need every key they list. Keys
    /// the leaves cannot tell apart, in that swapping two of them maps every
    /// leaf onto a leaf, belong to one member, whose threshold is how many
    /// of them each leaf holds; keys symmetric only because each is a
    /// member of its own (every leaf holds all of them, they are every key
    /// there is, or any one member spends and they never share a leaf)
    /// stay single members. The leaves must then be exactly every group of
    /// `threshold` members, each member in every way it meets its own
    /// threshold; nil otherwise. Pinned by NestedMultisigTests
    /// (thresholdMember, admissionRefusals) and held to the builder by
    /// `scripts/check-multisig-core`.
    static func members(of leaves: [(threshold: Int, keys: [Descriptor.SingleKey])]) -> Members? {
        guard leaves.allSatisfy({ $0.threshold == $0.keys.count }) else { return nil }
        let family = LeafFamily(leaves.map(\.keys))
        var groups: [[Data]] = []
        var thresholds: [Int] = []
        for keys in family.symmetryClasses() {
            if let threshold = family.memberThreshold(of: keys) {
                groups.append(keys)
                thresholds.append(threshold)
            } else {
                groups += keys.map { [$0] }
                thresholds += keys.map { _ in 1 }
            }
        }
        if family.groupSize(groups) == 1 {
            // Any one member spends: a member of which one key signs is the
            // same leaves as that many one-key members, so read it as them.
            let split = groups.indices.flatMap { thresholds[$0] == 1 ? groups[$0].map { [$0] } : [groups[$0]] }
            thresholds = split.map { groups.contains($0) ? thresholds[groups.firstIndex(of: $0)!] : 1 }
            groups = split
        }
        guard let threshold = family.groupSize(groups), family.matches(groups: groups, thresholds: thresholds, size: threshold)
        else { return nil }
        return Members(threshold: threshold, groups: groups.map { $0.map { family.key[$0]! } }, thresholds: thresholds)
    }

    /// Leaves as sets of key identities, for reading members back.
    private struct LeafFamily {
        /// Key identities in first-appearance order, each with its first key.
        var order: [Data] = []
        var key: [Data: Descriptor.SingleKey] = [:]
        var leaves: [Set<Data>] = []
        var family: Set<Set<Data>> = []

        init(_ lists: [[Descriptor.SingleKey]]) {
            for keys in lists {
                var leaf: Set<Data> = []
                for single in keys {
                    let identity = MultisigAccount.identity(of: single)
                    if key[identity] == nil {
                        order.append(identity)
                        key[identity] = single
                    }
                    leaf.insert(identity)
                }
                leaves.append(leaf)
                family.insert(leaf)
            }
        }

        /// Whether swapping `first` and `second` maps every leaf onto a leaf.
        func isSymmetric(_ first: Data, _ second: Data) -> Bool {
            leaves.allSatisfy { leaf in
                guard leaf.contains(first) != leaf.contains(second) else { return true }
                return family.contains(leaf.symmetricDifference([first, second]))
            }
        }

        /// The keys partitioned by symmetry, in first-appearance order.
        func symmetryClasses() -> [[Data]] {
            var classes: [[Data]] = []
            for identity in order {
                if let index = classes.firstIndex(where: { isSymmetric($0[0], identity) }) {
                    classes[index].append(identity)
                } else {
                    classes.append([identity])
                }
            }
            return classes
        }

        /// How a symmetry class reads: the threshold of one member made of
        /// its keys, or nil to read each key as a member of its own: when
        /// leaves hold varying numbers of its keys, when every leaf holds
        /// all of them, or when it is every key there is.
        func memberThreshold(of keys: [Data]) -> Int? {
            let present = leaves.map { $0.intersection(keys).count }.filter { $0 > 0 }
            let counts = Set(present)
            guard counts.count == 1, let threshold = counts.first else { return nil }
            let everywhere = present.count == leaves.count
            return (threshold == keys.count && everywhere) || keys.count == order.count ? nil : threshold
        }

        /// The number of members in every leaf, when it is the same for all.
        func groupSize(_ groups: [[Data]]) -> Int? {
            let sizes = Set(leaves.map { leaf in groups.filter { !leaf.isDisjoint(with: $0) }.count })
            return sizes.count == 1 ? sizes.first : nil
        }

        /// Whether the leaves are exactly every group of `size` members,
        /// each member in every way it meets `thresholds[i]` of its keys.
        func matches(groups: [[Data]], thresholds: [Int], size: Int) -> Bool {
            var expected: Set<Set<Data>> = []
            for group in MultisigAccount.combinations(of: Array(groups.indices), size: size) {
                let choices = group.map { member in
                    MultisigAccount.combinations(of: Array(groups[member].indices), size: thresholds[member])
                        .map { Set($0.map { groups[member][$0] }) }
                }
                for pick in MultisigAccount.product(choices) {
                    expected.insert(pick.reduce(into: Set<Data>()) { $0.formUnion($1) })
                }
            }
            return expected == family && expected.count == leaves.count
        }
    }

    /// "2 of 3" for an ordinary account, "2 of 3 members" for a nested one
    /// whose leaves read as members, "2 of 3 members, one of them 2 of 3"
    /// when a member is a threshold over its keys, else how many ways it
    /// can spend.
    public var policySummary: String {
        guard isNested else { return "\(threshold) of \(signers.count)" }
        guard let members else { return "\(signersLeaves.count) signing groups" }
        return "\(members.threshold) of \(members.groups.count) members" + Self.thresholdMembersText(members)
    }

    /// ", one of them 2 of 3"; ", two of them 2 of 3, one 1 of 2"; "" when
    /// every member signs with all its keys.
    static func thresholdMembersText(_ members: Members) -> String {
        var counts: [(policy: String, count: Int)] = []
        for group in members.thresholdGroups {
            let policy = "\(members.thresholds[group]) of \(members.groups[group].count)"
            if let index = counts.firstIndex(where: { $0.policy == policy }) {
                counts[index].count += 1
            } else {
                counts.append((policy, 1))
            }
        }
        let words = ["none", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        return counts.enumerated().map { position, entry in
            let word = entry.count < words.count ? words[entry.count] : "\(entry.count)"
            return ", \(word)\(position == 0 ? " of them" : "") \(entry.policy)"
        }.joined()
    }

    /// Whether one signer is this account public key, whatever origin label
    /// the descriptor gives it.
    public func includes(accountKey: HDKey) -> Bool {
        allKeys.contains { signer in
            guard case let .extended(base, _) = signer.base else { return false }
            return base.publicKey == accountKey.publicKey
        }
    }

    /// Whether `key` (a master or BIP86 account key) holds one signer.
    public func hasSigner(for key: HDKey) -> Bool {
        allKeys.contains { (try? Self.accountSecretKey(for: $0, from: key)) != nil }
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
        var path: SpendPath

        var isRecovery: Bool { path.isRecovery }
        var hash: Data { Taproot.leafHash(version: version, script: script) }
    }

    /// The first signers' leaf at (choice, index).
    func leaf(choice: Int, index: UInt32) throws -> Leaf {
        try leaves(choice: choice, index: index).first { $0.path == .signers }!
    }

    /// Every leaf at (choice, index) in tree order, with its control block.
    func leaves(choice: Int, index: UInt32) throws -> [Leaf] {
        let (internalKey, tree) = try descriptor.resolvedTaproot(index: index, choice: choice)
        let blocks = try Taproot.controlBlocks(internalKey: internalKey, tree: tree)
        var scripts: [(UInt8, Script)] = []
        func collect(_ node: Taproot.Tree) {
            switch node {
            case let .leaf(version, script): scripts.append((version, script))
            case let .branch(left, right):
                collect(left)
                collect(right)
            }
        }
        collect(tree)
        guard scripts.count == blocks.count, scripts.count == leafPaths.count else {
            throw MultisigAccountError.invalidDescriptor("the account's tree does not resolve to its leaves")
        }
        return scripts.enumerated().map { position, leaf in
            Leaf(internalKey: internalKey, version: leaf.0, script: leaf.1, controlBlock: blocks[position],
                 path: leafPaths[position])
        }
    }

    /// Whether `coin` may already be spent on the recovery path in the next
    /// block: confirmed at least `Recovery.blocks` blocks below it.
    public func isUnlockedForRecovery(_ coin: WalletUTXO, chainTip: UInt32) -> Bool {
        guard let recovery, coin.height > 0, chainTip >= coin.height else { return false }
        return chainTip - coin.height + 1 >= recovery.blocks
    }

    /// The first block in which `coin` can be spent on the recovery path;
    /// nil when it is unconfirmed or that block is past `UInt32.max`. Pinned
    /// in TimelockedMultisigTests.fewerSigners, and held to Bitcoin Core's
    /// BIP68 boundary, with `isUnlockedForRecovery`, by
    /// `scripts/check-multisig-core`.
    public func recoveryUnlockHeight(of coin: WalletUTXO) -> UInt32? {
        guard let recovery, coin.height > 0 else { return nil }
        let (unlock, overflow) = coin.height.addingReportingOverflow(recovery.blocks)
        return overflow ? nil : unlock
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
        let path = try spendPath(of: psbt)
        let inputTotal = try reviewedInputTotal(of: psbt, knownUTXOs: knownUTXOs, chainTip: chainTip, path: path)
        let outputs = try reviewedOutputs(of: psbt, inputTotal: inputTotal,
                                          ownedOutputCoordinates: ownedOutputCoordinates)
        let fee = inputTotal - outputs.total
        try Self.checkFeeCeiling(fee: fee, inputTotal: inputTotal)
        return SpendReview(outputs: outputs.reviewed, inputTotal: inputTotal, outputTotal: outputs.total, fee: fee,
                           path: path)
    }

    /// The recovery path when every input's sequence meets the recovery
    /// leaf's lock, otherwise the signers' path. The signers' leaves have no
    /// lock, so they can finish either: sequences that meet the lock come from
    /// a recovery spend or, on old coins, from a co-signer's BIP326
    /// anti-fee-sniping, and a mix can only finish on a signers' leaf.
    /// Exercised by the journey's recovery leg (UITests/MultisigJourney.swift)
    /// and, for a mix across two phones,
    /// AppTests/MultisigAccountFlowTests.testTwoPhonesSignACoSignersSpendWithBIP326Sequences.
    func spendPath(of psbt: PSBT) throws -> SpendPath {
        guard let recovery else { return .signers }
        let tx = try psbt.unsignedTransaction()
        let meetsLock = tx.inputs.allSatisfy {
            RelativeLock.isSatisfied(blocks: recovery.blocks, sequence: $0.sequence, txVersion: tx.version)
        }
        return meetsLock ? .recovery : .signers
    }

    private static let maxMoney: Int64 = 2_100_000_000_000_000

    /// One rule for the creator and every reviewer: at most 10% of the
    /// inputs may go to the miner.
    private static func checkFeeCeiling(fee: Int64, inputTotal: Int64) throws {
        guard fee <= inputTotal / 10 else {
            throw MultisigAccountError.invalidSpend("the \(fee)-sat fee exceeds the 10% safety limit for these inputs")
        }
    }

    private func reviewedInputTotal(of psbt: PSBT, knownUTXOs: [WalletUTXO], chainTip: UInt32,
                                    path: SpendPath) throws -> Int64 {
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
            if path.isRecovery, !isUnlockedForRecovery(known, chainTip: chainTip) {
                let unlock = recoveryUnlockHeight(of: known).map { "at block \($0)" }
                    ?? (known.height > 0 ? "past the last block height" : "once it confirms")
                throw MultisigAccountError.invalidSpend("input \(inputIndex + 1) unlocks for recovery only \(unlock)")
            }
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
            // In 64 bits: a stored height within 100 of the top must refuse, not trap.
            let matureAt = UInt64(known.height) + UInt64(Wallet.coinbaseMaturity) - 1
            guard UInt64(chainTip) >= matureAt else {
                throw MultisigAccountError.invalidSpend(
                    "input \(inputIndex + 1) spends a coinbase that matures in \(matureAt - UInt64(chainTip)) blocks")
            }
        }
        guard try scriptPubKey(index: known.index, choice: known.chain.rawValue) == known.scriptPubKey else {
            throw MultisigAccountError.invalidSpend("input \(inputIndex + 1) does not belong to this descriptor")
        }
        let rawSighash = input.sighashType ?? 0
        guard rawSighash == 0 || rawSighash == 1 else {
            throw MultisigAccountError.invalidSpend("input \(inputIndex + 1) does not commit to every output")
        }
        let expected = try leaves(choice: known.chain.rawValue, index: known.index)
        let expectedLeaves = expected.map {
            PSBT.TapLeafScript(controlBlock: $0.controlBlock, script: $0.script.bytes, leafVersion: $0.version)
        }
        let sortKey = { (leaf: PSBT.TapLeafScript) in leaf.controlBlock.serialized + leaf.script }
        let attached = input.tapLeafScripts.sorted { sortKey($0).lexicographicallyPrecedes(sortKey($1)) }
        guard input.tapInternalKey == expected.first?.internalKey,
              attached == expectedLeaves.sorted(by: { sortKey($0).lexicographicallyPrecedes(sortKey($1)) }) else {
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
                            feeRateSatPerVByte: Double, chainTip: UInt32, path: SpendPath = .signers,
                            randomness: @Sendable () -> Double = { Double.random(in: 0 ..< 1) }) throws -> PSBT {
        for utxo in utxos {
            guard try scriptPubKey(index: utxo.index, choice: utxo.chain.rawValue) == utxo.scriptPubKey else {
                throw MultisigAccountError.scriptMismatch(index: utxo.index, choice: utxo.chain.rawValue)
            }
        }
        let (spendable, sequence) = try spendableCoins(utxos, path: path, chainTip: chainTip)
        let changeScript = try scriptPubKey(index: changeIndex, choice: AddressChain.change.rawValue)
        let selection = try CoinSelection.select(utxos: spendable, payments: payments, changeScriptPubKey: changeScript,
                                                 feeRateSatPerVByte: feeRateSatPerVByte,
                                                 witnessBytesPerInput: try witnessBytesPerInput(path: path))
        try Self.checkFeeCeiling(fee: selection.fee, inputTotal: selection.selected.reduce(0) { $0 + $1.amount })
        let change = selection.changeAmount.map { Payment(amount: $0, scriptPubKey: changeScript) }
        let tx = try TransactionBuilder.build(
            inputs: selection.selected.map(\.outpoint), payments: payments, change: change, sequence: sequence,
            locktime: TransactionBuilder.antiFeeSnipingLocktime(tip: chainTip, randomness: randomness))
        var psbt = try PSBT(unsignedTx: tx,
                            inputs: selection.selected.map { PSBT.InputInfo(spentOutput: $0.spentOutput) },
                            outputs: tx.outputs.map { _ in PSBT.OutputInfo() })
        for (inputIndex, utxo) in selection.selected.enumerated() {
            let leaves = try leaves(choice: utxo.chain.rawValue, index: utxo.index)
            try psbt.attachScriptPaths(input: inputIndex,
                                       leaves: leaves.map { ($0.controlBlock, $0.script, $0.version) },
                                       keyOrigins: keyOrigins(choice: utxo.chain.rawValue, index: utxo.index))
        }
        if let change { try describeChange(change, index: changeIndex, in: &psbt) }
        return psbt
    }

    /// The coins a spend on `path` may use and the sequence its inputs carry:
    /// all of them on a signers' path; on the recovery path only those at
    /// least `Recovery.blocks` deep, with that many blocks as the sequence.
    private func spendableCoins(_ utxos: [WalletUTXO], path: SpendPath,
                                chainTip: UInt32) throws -> (coins: [WalletUTXO], sequence: UInt32) {
        guard path.isRecovery else { return (utxos, TransactionBuilder.defaultSequence) }
        guard let recovery else { throw MultisigAccountError.invalidSpend("this account has no recovery path") }
        let unlocked = utxos.filter { isUnlockedForRecovery($0, chainTip: chainTip) }
        guard !unlocked.isEmpty else {
            throw MultisigAccountError.invalidSpend(
                "no coin has stayed unmoved for \(recovery.blocks) blocks yet, so none can be recovered")
        }
        return (unlocked, recovery.blocks)
    }

    /// The internal key, tap tree and signer origins on the change output.
    private func describeChange(_ change: Payment, index changeIndex: UInt32, in psbt: inout PSBT) throws {
        let leaves = try leaves(choice: AddressChain.change.rawValue, index: changeIndex)
        for outputIndex in psbt.outputs.indices where psbt.outputs[outputIndex].script == change.scriptPubKey
            && psbt.outputs[outputIndex].amount == change.amount {
            psbt.outputs[outputIndex].tapInternalKey = leaves[0].internalKey
            // Right subtree first, as Bitcoin Core's TaprootBuilder lists it:
            // still a BIP371 depth-first order with the same Merkle root (a
            // branch hashes its children sorted, so the mirrored tree is the
            // same tree), and the bytes Core writes, so its PSBT combines
            // with ours. Each leaf's depth is the length of its Merkle path.
            psbt.outputs[outputIndex].tapTree = leaves.reversed().map {
                (depth: UInt8($0.controlBlock.path.count), leafVersion: $0.version, script: $0.script.bytes)
            }
            psbt.outputs[outputIndex].tapBIP32Derivation = try keyOrigins(
                choice: AddressChain.change.rawValue, index: changeIndex)
        }
    }

    /// Per-input witness bytes for fee estimation, exact for this account's
    /// spend on `path`: item count, one 64-byte signature or empty
    /// placeholder per key slot of that leaf (counted as signatures, the
    /// worst case), the leaf script and its control block (33 bytes, plus 32
    /// per level of the tree above the leaf), each length-prefixed. On a
    /// signers' path the largest signers' leaf: the creator does not know
    /// which group will finish the spend.
    func witnessBytesPerInput(path: SpendPath = .signers) throws -> Int {
        let leaves = try leaves(choice: 0, index: 0)
        let candidates = leaves.filter { $0.isRecovery == path.isRecovery }
        guard !candidates.isEmpty else { throw MultisigAccountError.invalidSpend("this account has no recovery path") }
        return candidates.map { leaf in
            let slots = keys(on: leaf.path).count
            let scriptSize = leaf.script.bytes.count
            let controlBlockSize = 33 + 32 * leaf.controlBlock.path.count
            return 1 + slots * 65 + Self.compactSizeLength(scriptSize) + scriptSize + 1 + controlBlockSize
        }.max()!
    }

    private static func compactSizeLength(_ value: Int) -> Int {
        value < 0xFD ? 1 : (value <= 0xFFFF ? 3 : 5)
    }

    /// BIP371 key origins for every key of every leaf at (choice, index):
    /// master fingerprint, the full path (origin path plus the suffix steps
    /// taken at (choice, index)) and the leaf hashes the derived key signs
    /// for. A signer in several leaves derives a different key in each, so
    /// each entry names one leaf.
    private func keyOrigins(choice: Int, index: UInt32) throws -> [Data: PSBT.KeyOrigin] {
        let leaves = try leaves(choice: choice, index: index)
        var origins: [Data: PSBT.KeyOrigin] = [:]
        for leaf in leaves {
            for key in keys(on: leaf.path) {
                guard let origin = key.origin else { continue }
                let xonly = Data(try descriptor.publicKey(of: key, index: index, choice: choice).dropFirst())
                var leafHashes = origins[xonly]?.leafHashes ?? []
                if !leafHashes.contains(leaf.hash) { leafHashes.append(leaf.hash) }
                origins[xonly] = PSBT.KeyOrigin(leafHashes: leafHashes, masterFingerprint: origin.fingerprint,
                                                path: origin.path + Self.suffixSteps(of: key, choice: choice, index: index))
            }
        }
        return origins
    }

    /// The suffix steps a key expression takes at (choice, index):
    /// `/<0;1>/*` gives choice, index; `/<2;3>/*` gives 2 + choice, index.
    static func suffixSteps(of key: Descriptor.SingleKey, choice: Int, index: UInt32) -> [UInt32] {
        key.derivation.elements.map { element in
            switch element {
            case let .step(step): step
            case let .multipath(values): values[choice]
            case let .wildcard(hardened): index + (hardened ? HDKey.hardenedOffset : 0)
            }
        }
    }

    // MARK: - Signing

    /// Reviews the spend, then adds a script-path signature to every input
    /// for each signer `key` holds (a master or the BIP86 account key itself),
    /// on every leaf that key is in. Throws `noSignerKey` when an input has
    /// no signer this key can sign for.
    public func sign(_ psbt: inout PSBT, signingKey key: HDKey, knownUTXOs: [WalletUTXO],
                     ownedOutputCoordinates: [OutputCoordinate], chainTip: UInt32) throws {
        _ = try reviewSpend(psbt, knownUTXOs: knownUTXOs, ownedOutputCoordinates: ownedOutputCoordinates,
                            chainTip: chainTip)
        var signed = psbt
        for input in signed.inputs.indices {
            let utxo = try coin(for: signed, input: input, knownUTXOs: knownUTXOs)
            var secrets: [Data] = []
            for signer in allKeys {
                guard let account = try Self.accountSecretKey(for: signer, from: key) else { continue }
                var child = account
                for step in Self.suffixSteps(of: signer, choice: utxo.chain.rawValue, index: utxo.index) {
                    child = try child.child(at: step)
                }
                guard let secret = child.privateKey else { continue }
                secrets.append(secret)
            }
            guard !secrets.isEmpty else { throw MultisigAccountError.noSignerKey(input: input) }
            try signed.signScriptPath(input: input, privateKeys: secrets)
        }
        psbt = signed
    }

    /// Which signers (by position on the first signers' leaf) have a verified
    /// signature on every input, judged by BIP340 verification against the
    /// recomputed sighash, never by the presence of an entry or any label in
    /// the PSBT.
    public func approvals(of psbt: PSBT, knownUTXOs: [WalletUTXO]) throws -> Set<Int> {
        try approvals(of: psbt, knownUTXOs: knownUTXOs, path: .signers)
    }

    /// Which keys of `path`'s leaf (by position among that leaf's keys)
    /// have a verified signature on that leaf of every input.
    public func approvals(of psbt: PSBT, knownUTXOs: [WalletUTXO], path: SpendPath) throws -> Set<Int> {
        let keys = keys(on: path)
        guard !keys.isEmpty else { return [] }
        let tx = try psbt.unsignedTransaction()
        let spentOutputs = try psbt.spentOutputs()
        var approved: Set<Int>?
        for input in psbt.inputs.indices {
            let utxo = try coin(for: psbt, input: input, knownUTXOs: knownUTXOs)
            guard let leaf = try leaves(choice: utxo.chain.rawValue, index: utxo.index)
                .first(where: { $0.path == path }) else { return [] }
            let verified = try psbt.verifiedScriptPathSigners(input: input, leafHash: leaf.hash, tx: tx,
                                                              spentOutputs: spentOutputs)
            var here: Set<Int> = []
            for (position, key) in keys.enumerated() {
                let derived = try descriptor.publicKey(of: key, index: utxo.index, choice: utxo.chain.rawValue)
                if verified.contains(Data(derived.dropFirst())) { here.insert(position) }
            }
            approved = approved.map { $0.intersection(here) } ?? here
        }
        return approved ?? []
    }

    /// Finalizes a PSBT with at least `threshold` verified signatures per
    /// input on some leaf and extracts the raw transaction, after one more
    /// review.
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
