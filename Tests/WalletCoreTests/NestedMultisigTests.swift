import Foundation
import Testing
import TestSupport
@testable import WalletCore

/// Nested accounts: members that sign together as one, expanded into a leaf
/// per group of members. The builder and what it writes, what joining
/// admits and refuses, spends finishing on one leaf or none, and the
/// Ledger policy with one and two simulated Ledgers.
@Suite("Nested multisig")
struct NestedMultisigTests {
    let destination = Data([0x51, 0x20] + repeatElement(0x77, count: 32))
    let owned = [MultisigAccount.OutputCoordinate(choice: 1, index: 0)]

    /// Member A holds two keys (a phone and its Ledger, both software here),
    /// B and C one each: any two members spend.
    struct Family {
        /// 0 and 1 are A's, 2 is B's, 3 is C's.
        var masters: [HDKey]
        var members: [[String]]
        var account: MultisigAccount

        /// The signers' leaf whose keys are exactly these masters', by position.
        func leaf(of holders: [Int]) throws -> MultisigAccount.SpendPath {
            let wanted = Set(try holders.map { try masters[$0].derived(path: "m/86'/1'/0'").publicKey })
            let position = try #require(account.signersLeaves.firstIndex { leaf in
                Set(leaf.keys.map { MultisigAccount.identity(of: $0) }) == wanted
            })
            return .signers(position)
        }
    }

    static func family(threshold: Int = 2, recovery: MultisigAccount.RecoveryPlan? = nil) throws -> Family {
        let masters = try [0xA1, 0xB2, 0xC3, 0xD4].map { try TestKeys.master(entropyByte: $0) }
        let keys = try masters.map { try TestKeys.keyExpression(master: $0) }
        let members = [[keys[0], keys[1]], [keys[2]], [keys[3]]]
        let descriptor = try MultisigAccount.descriptor(members: members, threshold: threshold, recovery: recovery,
                                                        network: .signet)
        return Family(masters: masters, members: members,
                      account: try MultisigAccount(descriptor: descriptor, network: .signet))
    }

    static func funding(_ account: MultisigAccount, amount: Int64 = 100_000, height: UInt32 = 100) throws -> WalletUTXO {
        try WalletUTXO(txid: Data(repeating: 0x6E, count: 32), vout: 0, amount: amount,
                       scriptPubKey: account.scriptPubKey(index: 0), chain: .receive, index: 0, height: height)
    }

    func spend(_ account: MultisigAccount, _ coin: WalletUTXO, path: MultisigAccount.SpendPath = .signers) throws -> PSBT {
        try account.createSpend(utxos: [coin], payments: [Payment(amount: 40_000, scriptPubKey: destination)],
                                changeIndex: 0, feeRateSatPerVByte: 2, chainTip: 101, path: path, randomness: { 0.5 })
    }

    // MARK: - The builder

    @Test("2 of 3 members, one of them two keys: three leaves, every key on its next pair when reused")
    func builder() throws {
        let family = try Self.family()
        let account = family.account
        #expect(account.isNested)
        #expect(account.signersLeaves.count == 3)
        #expect(account.signersLeaves.map { $0.keys.count }.sorted() == [2, 3, 3])
        #expect(account.signersLeaves.allSatisfy { $0.threshold == $0.keys.count && $0.isSorted })
        #expect(account.signers.count == 4)
        #expect(account.recovery == nil)
        #expect(account.policySummary == "2 of 3 members")
        let members = try #require(account.members)
        #expect(members.threshold == 2)
        #expect(members.groups.map(\.count).sorted() == [1, 1, 2])
        // Each key sits in two leaves: on /<0;1>/* first, /<2;3>/* after.
        var appearances: [Data: [Int]] = [:]
        for leaf in account.signersLeaves {
            for key in leaf.keys {
                appearances[MultisigAccount.identity(of: key), default: []].append(
                    try #require(MultisigAccount.appearance(of: key.derivation.elements)))
            }
        }
        #expect(appearances.count == 4 && appearances.values.allSatisfy { $0 == [0, 1] })
        // The text round-trips and derives the same addresses.
        let text = account.descriptor.serialized()
        #expect(text.hasPrefix("tr(tpub") && text.contains("{{sortedmulti_a(") && text.contains("/<2;3>/*"))
        let again = try MultisigAccount(text, network: .signet)
        #expect(again.signersLeaves == account.signersLeaves)
        #expect(try again.address(index: 3, choice: 1) == account.address(index: 3, choice: 1))
        #expect(account.includes(accountKey: try family.masters[3].derived(path: "m/86'/1'/0'").neutered))
        #expect(account.hasSigner(for: family.masters[1]))
    }

    @Test("members and keys in any order give one descriptor; single-key members give the ordinary account")
    func orderDoesNotMatter() throws {
        let family = try Self.family()
        let keys = family.members
        let shuffled = [keys[2], [keys[0][1], keys[0][0]], keys[1]]
        let other = try MultisigAccount.descriptor(members: shuffled, threshold: 2, network: .signet)
        #expect(other.serialized() == family.account.descriptor.serialized())
        let flat = try MultisigAccount.descriptor(members: [[keys[0][0]], keys[1], keys[2]], threshold: 2, network: .signet)
        let plain = try MultisigAccount.descriptor(threshold: 2, signers: [keys[0][0], keys[1][0], keys[2][0]],
                                                   network: .signet)
        #expect(flat.serialized() == plain.serialized())
        #expect(!(try MultisigAccount(descriptor: flat, network: .signet)).isNested)
    }

    @Test("a 3-of-6 of pairs has too many leaves; a nested account's recovery path takes separate keys")
    func builderRefusals() throws {
        let pairs = try (0 ..< 12).map { try TestKeys.keyExpression(master: TestKeys.master(entropyByte: 0x10 + UInt8($0))) }
        let members = (0 ..< 6).map { [pairs[2 * $0], pairs[2 * $0 + 1]] }
        #expect(throws: MultisigAccountError.self) {
            _ = try MultisigAccount.descriptor(members: members, threshold: 3, network: .signet)
        }
        // A 3-of-5 of pairs is the most: ten leaves.
        let five = try MultisigAccount(descriptor: MultisigAccount.descriptor(members: Array(members.prefix(5)), threshold: 3,
                                                                              network: .signet), network: .signet)
        #expect(five.signersLeaves.count == 10 && five.members?.threshold == 3)
        #expect(throws: MultisigAccountError.invalidDescriptor("a nested account's recovery path takes separate keys")) {
            _ = try Self.family(recovery: .fewerSigners(threshold: 1, blocks: 10))
        }
        let separate = try Self.family(recovery: .separateKeys(
            threshold: 1, keys: [try TestKeys.keyExpression(master: TestKeys.master(entropyByte: 0xE5))], blocks: 10))
        #expect(separate.account.recovery?.keys.count == 1 && separate.account.signersLeaves.count == 3)
        #expect(try separate.account.leaves(choice: 0, index: 0).count == 4)
        // A member's key as the separate recovery key would need its third pair.
        #expect(throws: MultisigAccountError.self) {
            _ = try Self.family(recovery: .separateKeys(threshold: 1, keys: [Self.family().members[1][0]], blocks: 10))
        }
        #expect(throws: MultisigAccountError.self) {
            _ = try MultisigAccount.descriptor(members: [[pairs[0], pairs[1]], [pairs[1]]], threshold: 1, network: .signet)
        }
        #expect(throws: MultisigAccountError.self) {
            _ = try MultisigAccount.descriptor(members: [[pairs[0], pairs[1]]], threshold: 1, network: .signet)
        }
        // One of three members alone would let a one-key member spend alone;
        // it is fine when every member is a pair. Every member together is
        // one leaf of every key, the ordinary account.
        #expect(throws: MultisigAccountError.self) {
            _ = try MultisigAccount.descriptor(members: [[pairs[0], pairs[1]], [pairs[2]], [pairs[3]]], threshold: 1,
                                               network: .signet)
        }
        let anyPair = try MultisigAccount(descriptor: MultisigAccount.descriptor(members: Array(members.prefix(3)), threshold: 1,
                                                                                 network: .signet), network: .signet)
        #expect(anyPair.signersLeaves.count == 3 && anyPair.members?.threshold == 1)
        let everyone = try MultisigAccount(descriptor: MultisigAccount.descriptor(members: Array(members.prefix(2)), threshold: 2,
                                                                                  network: .signet), network: .signet)
        #expect(!everyone.isNested && everyone.threshold == 4 && everyone.signers.count == 4)
        #expect(everyone.descriptor.serialized()
            == (try MultisigAccount.descriptor(threshold: 4, signers: Array(pairs.prefix(4)), network: .signet)).serialized())
    }

    @Test("joining refuses a shared key on the same pair twice, a repeated group, a one-key leaf and a relabelled signer")
    func admissionRefusals() throws {
        let keys = try [0xA1, 0xB2, 0xC3].map { try TestKeys.bareKeyExpression(master: TestKeys.master(entropyByte: $0)) }
        let nums = Taproot.unspendableInternalKey.hex
        let good = "tr(\(nums),{sortedmulti_a(2,\(keys[0])/<0;1>/*,\(keys[1])/<0;1>/*),sortedmulti_a(2,\(keys[0])/<2;3>/*,\(keys[2])/<0;1>/*)})"
        let account = try MultisigAccount(good, network: .signet)
        #expect(account.isNested && account.members == nil && account.policySummary == "2 signing groups")
        let refused = [
            // The shared key on /<0;1>/* in both leaves.
            "{sortedmulti_a(2,\(keys[0])/<0;1>/*,\(keys[1])/<0;1>/*),sortedmulti_a(2,\(keys[0])/<0;1>/*,\(keys[2])/<0;1>/*)}",
            // The shared key skipping a pair.
            "{sortedmulti_a(2,\(keys[0])/<0;1>/*,\(keys[1])/<0;1>/*),sortedmulti_a(2,\(keys[0])/<4;5>/*,\(keys[2])/<0;1>/*)}",
            // The same group twice.
            "{sortedmulti_a(2,\(keys[0])/<0;1>/*,\(keys[1])/<0;1>/*),sortedmulti_a(2,\(keys[0])/<2;3>/*,\(keys[1])/<2;3>/*)}",
            // A one-key leaf.
            "{sortedmulti_a(2,\(keys[0])/<0;1>/*,\(keys[1])/<0;1>/*),multi_a(1,\(keys[2])/<0;1>/*)}",
            // The shared key under another fingerprint in the second leaf.
            "{sortedmulti_a(2,\(keys[0])/<0;1>/*,\(keys[1])/<0;1>/*),sortedmulti_a(2,[deadbeef\(keys[0].dropFirst(9))/<2;3>/*,\(keys[2])/<0;1>/*)}",
            // Two recovery leaves.
            "{{sortedmulti_a(2,\(keys[0])/<0;1>/*,\(keys[1])/<0;1>/*),and_v(v:pk(\(keys[2])/<0;1>/*),older(10))},and_v(v:pk(\(keys[2])/<2;3>/*),older(20))}",
        ]
        for tree in refused {
            #expect(throws: MultisigAccountError.self, "accepted \(tree.prefix(60))") {
                _ = try MultisigAccount("tr(\(nums),\(tree))", network: .signet)
            }
        }
        // A recovery leaf beside two signers' leaves, with the shared key on its third pair.
        let withRecovery = "tr(\(nums),{{sortedmulti_a(2,\(keys[0])/<0;1>/*,\(keys[1])/<0;1>/*),sortedmulti_a(2,\(keys[0])/<2;3>/*,\(keys[2])/<0;1>/*)},and_v(v:pk(\(keys[0])/<4;5>/*),older(10))})"
        let recovering = try MultisigAccount(withRecovery, network: .signet)
        #expect(recovering.recovery?.blocks == 10 && recovering.signersLeaves.count == 2)
        #expect(try recovering.leaves(choice: 0, index: 0).map(\.isRecovery) == [false, false, true])
    }

    // MARK: - Spends

    @Test("a spend finishes on the leaf of the two members that signed, and not for one member or half of one")
    func spends() throws {
        let family = try Self.family()
        let account = family.account
        let coin = try Self.funding(account)
        var psbt = try spend(account, coin)
        #expect(psbt.inputs[0].tapLeafScripts.count == 3)
        let changeTree = try #require(psbt.outputs.compactMap { $0.tapTree }.first)
        let leaves = try account.leaves(choice: 1, index: 0)
        #expect(changeTree.map { $0.script } == leaves.map { $0.script.bytes }.reversed())
        #expect(changeTree.map { Int($0.depth) } == leaves.map { $0.controlBlock.path.count }.reversed())
        #expect(changeTree.map { Int($0.depth) }.sorted() == [1, 2, 2])

        let ab = try family.leaf(of: [0, 1, 2])
        let ac = try family.leaf(of: [0, 1, 3])
        let bc = try family.leaf(of: [2, 3])
        func sign(_ holder: Int) throws {
            try account.sign(&psbt, signingKey: family.masters[holder], knownUTXOs: [coin], ownedOutputCoordinates: owned,
                             chainTip: 101)
        }
        // A's phone alone: a signature on both of A's leaves, nothing finishes.
        try sign(0)
        #expect(try account.approvals(of: psbt, knownUTXOs: [coin], path: ab).count == 1)
        #expect(try account.approvals(of: psbt, knownUTXOs: [coin], path: ac).count == 1)
        #expect(try account.approvals(of: psbt, knownUTXOs: [coin], path: bc).isEmpty)
        #expect(throws: (any Error).self) { var copy = psbt; _ = try copy.finalize() }
        // A's Ledger key too: one whole member is still one member.
        try sign(1)
        #expect(try account.approvals(of: psbt, knownUTXOs: [coin], path: ab).count == 2)
        #expect(throws: (any Error).self) { var copy = psbt; _ = try copy.finalize() }
        // B completes the A-and-B leaf: three signatures, that leaf's script
        // and its control block, as many levels deep as the tree puts it.
        try sign(2)
        #expect(try account.approvals(of: psbt, knownUTXOs: [coin], path: ab).count == 3)
        #expect(try account.approvals(of: psbt, knownUTXOs: [coin], path: bc).count == 1)
        let transaction = try account.finalizeSpend(&psbt, knownUTXOs: [coin], ownedOutputCoordinates: owned, chainTip: 101)
        let witness = transaction.inputs[0].witness
        #expect(witness.count == 5 && witness.prefix(3).allSatisfy { $0.count == 64 })
        let receiveLeaves = try account.leaves(choice: 0, index: 0)
        let abLeaf = try #require(receiveLeaves.first { $0.path == ab })
        #expect(witness[3] == abLeaf.script.bytes)
        #expect(witness[4].count == 33 + 32 * abLeaf.controlBlock.path.count)
        #expect(TimelockedMultisigTests.witnessSize(witness) <= (try account.witnessBytesPerInput(path: .signers)))

        // B and C alone, the two one-key members: two signatures on their leaf.
        var other = try spend(account, coin)
        for holder in [2, 3] {
            try account.sign(&other, signingKey: family.masters[holder], knownUTXOs: [coin], ownedOutputCoordinates: owned,
                             chainTip: 101)
        }
        #expect(try account.approvals(of: other, knownUTXOs: [coin], path: bc) == [0, 1])
        let second = try account.finalizeSpend(&other, knownUTXOs: [coin], ownedOutputCoordinates: owned, chainTip: 101)
        #expect(second.inputs[0].witness.count == 4)
        #expect(second.inputs[0].witness[2] == (try #require(receiveLeaves.first { $0.path == bc })).script.bytes)
    }

    @Test("after the delay the separate recovery key spends alone; before it, only two members do")
    func recovery() throws {
        let recoveryMaster = try TestKeys.master(entropyByte: 0xE5)
        let family = try Self.family(recovery: .separateKeys(
            threshold: 1, keys: [try TestKeys.keyExpression(master: recoveryMaster)], blocks: 10))
        let account = family.account
        let coin = try Self.funding(account)
        #expect(throws: MultisigAccountError.self) { _ = try spend(account, coin, path: .recovery) }
        var later = try account.createSpend(utxos: [coin], payments: [Payment(amount: 40_000, scriptPubKey: destination)],
                                            changeIndex: 0, feeRateSatPerVByte: 2, chainTip: 109, path: .recovery,
                                            randomness: { 0.5 })
        #expect(try account.reviewSpend(later, knownUTXOs: [coin], ownedOutputCoordinates: owned, chainTip: 109).path
            == .recovery)
        try account.sign(&later, signingKey: recoveryMaster, knownUTXOs: [coin], ownedOutputCoordinates: owned, chainTip: 109)
        #expect(try account.approvals(of: later, knownUTXOs: [coin], path: .recovery) == [0])
        let transaction = try account.finalizeSpend(&later, knownUTXOs: [coin], ownedOutputCoordinates: owned, chainTip: 109)
        #expect(transaction.inputs[0].sequence == 10 && transaction.inputs[0].witness.count == 3)
    }

    // MARK: - Ledgers

    /// A's Ledger is a simulator: its key sits at the Ledger path, the policy
    /// registers the whole tree, and it signs every leaf it is in.
    @Test("the Ledger policy carries the whole tree; a Ledger signs both leaves it is in")
    func ledgerPolicy() async throws {
        let masters = try [0xA1, 0xB2, 0xC3, 0xD4].map { try TestKeys.master(entropyByte: $0) }
        let simulator = LedgerSimulator(master: masters[1])
        let client = LedgerBitcoinClient(transport: simulator)
        let (ledgerKey, fingerprint) = try await LedgerMultisig.signerExpression(client: client, network: .signet)
        let keys = try masters.map { try TestKeys.keyExpression(master: $0) }
        let descriptor = try MultisigAccount.descriptor(members: [[keys[0], ledgerKey], [keys[2]], [keys[3]]], threshold: 2,
                                                        network: .signet)
        let account = try MultisigAccount(descriptor: descriptor, network: .signet)
        let policy = try LedgerWalletPolicy(name: "Three households", account: account)
        #expect(policy.keys.count == 5)
        #expect(policy.template.hasPrefix("tr(@0/**,{{sortedmulti_a("))
        #expect(policy.template.components(separatedBy: "/**").count - 1 == 5)
        #expect(policy.template.components(separatedBy: "/<2;3>/*").count - 1 == 4)
        #expect(LedgerMultisig.hasLedgerSigner(account, fingerprint: fingerprint))
        #expect(LedgerMultisig.namesALedgerKey(account))
        let registration = try await LedgerMultisig.register(account, name: "Three households", fingerprint: fingerprint,
                                                             client: client)
        let shown = try await LedgerMultisig.displayAddress(account, registration: registration, index: 2, client: client)
        #expect(shown == (try account.address(index: 2)))
        var record = MultisigAccountRecord(id: account.id, name: "Three households", descriptor: descriptor.serialized(),
                                           createdAtHeight: 0, ledger: registration)
        try record.checkLedgerRegistration(for: account)
        record.ledger?.keyPath = [HDKey.hardenedOffset + 86, HDKey.hardenedOffset + 1, HDKey.hardenedOffset]
        #expect(throws: MultisigAccountError.self) { try record.checkLedgerRegistration(for: account) }

        let coin = try Self.funding(account)
        var psbt = try spend(account, coin)
        try account.sign(&psbt, signingKey: masters[0], knownUTXOs: [coin], ownedOutputCoordinates: owned, chainTip: 101)
        let added = try await LedgerMultisig.sign(&psbt, account: account, registration: registration, client: client)
        #expect(added == 2)
        #expect(throws: (any Error).self) { var copy = psbt; _ = try copy.finalize() }
        try account.sign(&psbt, signingKey: masters[3], knownUTXOs: [coin], ownedOutputCoordinates: owned, chainTip: 101)
        let transaction = try account.finalizeSpend(&psbt, knownUTXOs: [coin], ownedOutputCoordinates: owned, chainTip: 101)
        #expect(transaction.inputs[0].witness.count == 5, "the phone's, the Ledger's and C's signatures, the leaf, its control block")
    }

    @Test("two phones, each with its Ledger, and a third key: both households sign and the spend finishes")
    func twoLedgers() async throws {
        let phones = try [0xA1, 0xC3].map { try TestKeys.master(entropyByte: $0) }
        let simulators = try [0xB2, 0xD5].map { LedgerSimulator(master: try TestKeys.master(entropyByte: $0)) }
        let clients = simulators.map { LedgerBitcoinClient(transport: $0) }
        var ledgerKeys: [(expression: String, fingerprint: UInt32)] = []
        for client in clients {
            ledgerKeys.append(try await LedgerMultisig.signerExpression(client: client, network: .signet))
        }
        let third = try TestKeys.master(entropyByte: 0xD4)
        let members = [
            [try TestKeys.keyExpression(master: phones[0]), ledgerKeys[0].expression],
            [try TestKeys.keyExpression(master: phones[1]), ledgerKeys[1].expression],
            [try TestKeys.keyExpression(master: third)],
        ]
        let account = try MultisigAccount(descriptor: MultisigAccount.descriptor(members: members, threshold: 2,
                                                                                network: .signet), network: .signet)
        var registrations: [LedgerRegistration] = []
        for (client, key) in zip(clients, ledgerKeys) {
            registrations.append(try await LedgerMultisig.register(account, name: "Two households", fingerprint: key.fingerprint,
                                                                   client: client))
        }
        let coin = try Self.funding(account)
        var psbt = try spend(account, coin)
        try account.sign(&psbt, signingKey: phones[0], knownUTXOs: [coin], ownedOutputCoordinates: owned, chainTip: 101)
        try await LedgerMultisig.sign(&psbt, account: account, registration: registrations[0], client: clients[0])
        try account.sign(&psbt, signingKey: phones[1], knownUTXOs: [coin], ownedOutputCoordinates: owned, chainTip: 101)
        #expect(throws: (any Error).self) { var copy = psbt; _ = try copy.finalize() }
        try await LedgerMultisig.sign(&psbt, account: account, registration: registrations[1], client: clients[1])
        let complete = account.signersPaths.filter {
            (try? account.approvals(of: psbt, knownUTXOs: [coin], path: $0))?.count == account.threshold(on: $0)
        }
        #expect(complete.count == 1 && account.keys(on: complete[0]).count == 4)
        let transaction = try account.finalizeSpend(&psbt, knownUTXOs: [coin], ownedOutputCoordinates: owned, chainTip: 101)
        #expect(transaction.inputs[0].witness.count == 6)
    }
}
