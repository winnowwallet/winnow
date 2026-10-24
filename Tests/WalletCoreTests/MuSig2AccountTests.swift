import Foundation
import NativeSecp256k1
import Testing
import TestSupport
@testable import WalletCore

/// The raw MuSig2 account: who may be a participant, what a spend proposal
/// must be before this device signs it, and complete n-of-n spends through
/// serialized PSBTs (signet format, fully offline).
@Suite("MuSig2 account")
struct MuSig2AccountTests {
    /// An external P2TR destination.
    let destination = Data([0x51, 0x20] + repeatElement(0x77, count: 32))

    static func account(_ count: Int = 2) throws -> (account: MuSig2Account, masters: [HDKey]) {
        let masters = Array(try TestKeys.masters().prefix(count))
        let keys = try masters.map { try TestKeys.bareKeyExpression(master: $0) }
        let account = try MuSig2Account("tr(musig(\(keys.joined(separator: ",")))/<0;1>/*)", network: .signet)
        return (account, masters)
    }

    /// A fabricated confirmed coin paying the account at (chain, index).
    static func funding(_ account: MuSig2Account, amount: Int64, chain: AddressChain = .receive,
                        index: UInt32 = 0, vout: UInt32 = 0, height: UInt32 = 100) throws -> WalletUTXO {
        try WalletUTXO(txid: Data(repeating: 0x5A, count: 32), vout: vout, amount: amount,
                       scriptPubKey: account.scriptPubKey(index: index, choice: chain.rawValue),
                       chain: chain, index: index, height: height)
    }

    static let changeCoordinates = [MuSig2Account.OutputCoordinate(choice: AddressChain.change.rawValue, index: 0)]

    func spend(_ account: MuSig2Account, _ utxos: [WalletUTXO], feeRate: Double = 2) throws -> PSBT {
        try account.createSpend(utxos: utxos, payments: [Payment(amount: 50_000, scriptPubKey: destination)],
                                changeIndex: 0, feeRateSatPerVByte: feeRate, chainTip: testChainTip,
                                randomness: { 0.5 })
    }

    func review(_ account: MuSig2Account, _ psbt: PSBT, _ utxos: [WalletUTXO],
                chainTip: UInt32 = testChainTip) throws -> MuSig2Account.SpendReview {
        try account.reviewSpend(psbt, knownUTXOs: utxos, ownedOutputCoordinates: Self.changeCoordinates,
                                chainTip: chainTip)
    }

    // MARK: - Admission

    @Test("distinct participants make an account; its id is the descriptor checksum")
    func distinctParticipantsAccepted() throws {
        let (account, masters) = try Self.account()
        #expect(try account.address(index: 0).hasPrefix("tb1p"))
        #expect(account.id.count == 8 && account.descriptor.serialized().hasSuffix("#" + account.id))
        #expect(account.hasParticipant(for: masters[0]))
        #expect(account.hasParticipant(for: try masters[1].derived(path: "m/86'/1'/0'")),
                "an account-key-only wallet holds its participant too")
        #expect(!account.hasParticipant(for: try TestKeys.masters()[2]))
        #expect(!account.hasParticipant(for: masters[0].neutered), "a public key holds no secret")
        // Receive and change for each index, in order.
        let scripts = try account.watchScripts(upTo: 2)
        #expect(scripts == [try account.scriptPubKey(index: 0, choice: 0), try account.scriptPubKey(index: 0, choice: 1),
                            try account.scriptPubKey(index: 1, choice: 0), try account.scriptPubKey(index: 1, choice: 1)])
        #expect(Set(scripts).count == 4)
    }

    /// `musig(K, K)` presents as 2-of-2 while whoever holds K spends alone.
    /// Origins are unauthenticated labels, so the comparison is on key material.
    @Test("a repeated participant is refused, relabelled or in any position")
    func repeatedParticipantRefused() throws {
        let masters = try TestKeys.masters()
        let a = try TestKeys.bareKeyExpression(master: masters[0])
        let b = try TestKeys.bareKeyExpression(master: masters[1])
        let bracket = try #require(a.firstIndex(of: "]"))
        let relabelled = "[deadbeef/86'/1'/0']" + a[a.index(after: bracket)...]
        for participants in [[a, a], [a, relabelled], [a, b, a], [b, a, relabelled]] {
            #expect(throws: MuSig2AccountError.self) {
                _ = try MuSig2Account("tr(musig(\(participants.joined(separator: ",")))/<0;1>/*)", network: .signet)
            }
        }
        _ = try MuSig2Account("tr(musig(\(a),\(b))/<0;1>/*)", network: .signet)
    }

    @Test("only tr(musig(XPUB, XPUB, ...)/<0;1>/*) with origin-bearing public keys is an account")
    func shapeRefusals() throws {
        let masters = try TestKeys.masters()
        let a = try TestKeys.bareKeyExpression(master: masters[0])
        let b = try TestKeys.bareKeyExpression(master: masters[1])
        let account = try masters[1].derived(path: "m/86'/1'/0'")
        let fingerprint = String(format: "%08x", masters[1].fingerprint)
        let tpub = account.neutered.serialized(network: .testnet)
        let refused = [
            "tr(\(a)/<0;1>/*)", // a single key
            "tr(musig(\(a))/<0;1>/*)", // one participant
            "tr(musig(\(a),\(b)))", // no suffix
            "tr(musig(\(a),\(b))/0/*)", // a single path
            "tr(musig(\(a),\(b))/<1;0>/*)", // receive and change swapped
            "tr(musig(\(a),\(b)/0)/<0;1>/*)", // a participant with its own suffix
            "tr(musig(\(a),\(tpub))/<0;1>/*)", // no origin
            "tr(musig(\(a),[\(fingerprint)/86'/1']\(tpub))/<0;1>/*)", // origin shorter than the key's depth
            "tr(musig(\(a),[\(fingerprint)/86'/1'/1']\(tpub))/<0;1>/*)", // origin ending at another child
            "tr(musig(\(a),[\(fingerprint)/86'/1'/0']\(account.serialized(network: .testnet)))/<0;1>/*)", // private
        ]
        for text in refused {
            #expect(throws: (any Error).self, "\(text.prefix(40))") { _ = try MuSig2Account(text, network: .signet) }
        }
        // The same signet keys are refused for a mainnet account.
        #expect(throws: MuSig2AccountError.self) {
            _ = try MuSig2Account("tr(musig(\(a),\(b))/<0;1>/*)", network: .mainnet)
        }
    }

    // MARK: - Review

    @Test("review trusts known coins and descriptor scripts, not PSBT fields")
    func reviewRules() throws {
        let (account, _) = try Self.account()
        let utxo = try Self.funding(account, amount: 100_000)
        let created = try spend(account, [utxo])
        let reviewed = try review(account, created, [utxo])
        #expect(reviewed.inputTotal == 100_000 && reviewed.outputTotal + reviewed.fee == reviewed.inputTotal)
        #expect(reviewed.outputs.first { $0.scriptPubKey == destination }?.isAccountOwned == false)
        #expect(reviewed.outputs.first { $0.scriptPubKey != destination }?.isAccountOwned == true)
        // The change output carries the BIP328-derived internal key.
        let changeIndex = try #require(created.outputs.firstIndex { $0.script != destination })
        let paymentIndex = try #require(created.outputs.firstIndex { $0.script == destination })
        #expect(created.outputs[changeIndex].tapInternalKey == (try account.muSig2Context(choice: 1, index: 0)).internalKey)

        // Output metadata copied onto the payment does not make it ours.
        var forged = created
        forged.outputs[paymentIndex].tapInternalKey = created.outputs[changeIndex].tapInternalKey
        #expect(try review(account, forged, [utxo]).outputs[paymentIndex].isAccountOwned == false)

        let mutations: [(String, (inout PSBT) -> Void)] = [
            ("wrong amount", { $0.inputs[0].witnessUTXO = .init(amount: utxo.amount + 1, scriptPubKey: utxo.scriptPubKey) }),
            ("SIGHASH_NONE", { $0.inputs[0].sighashType = 2 }),
            ("SIGHASH_ALL|ANYONECANPAY", { $0.inputs[0].sighashType = 0x81 }),
            ("internal key", { $0.inputs[0].tapInternalKey = Data(repeating: 0x44, count: 32) }),
            ("participants", { psbt in
                var fields = psbt.inputs[0].musig2ParticipantPubKeys
                for key in fields.keys { fields[key]?.reverse() }
                psbt.inputs[0].musig2ParticipantPubKeys = fields
            }),
            ("no participants", { $0.inputs[0].musig2ParticipantPubKeys = [:] }),
            ("absurd fee", { $0.outputs[paymentIndex].amount = 1; $0.outputs[changeIndex].amount = 1 }),
            ("outputs exceed inputs", { $0.outputs[paymentIndex].amount = 100_000 }),
            ("zero output", { $0.outputs[paymentIndex].amount = 0 }),
            ("too many outputs", { $0.outputs = Array(repeating: created.outputs[0], count: 1_001) }),
            ("version 3", { psbt in
                psbt.globals.removeAll { $0.type == PSBT.GlobalType.txVersion }
                psbt.globals.append(PSBT.KeyValue(type: PSBT.GlobalType.txVersion, value: Data([3, 0, 0, 0])))
            }),
            ("repeated input", { $0.inputs.append($0.inputs[0]) }),
        ]
        for (name, mutate) in mutations {
            var psbt = created
            mutate(&psbt)
            #expect(throws: MuSig2AccountError.self, "\(name)") { _ = try review(account, psbt, [utxo]) }
        }
    }

    @Test("a coin this account never saw, or another account's coin, is refused")
    func foreignInputRefused() throws {
        let (account, _) = try Self.account()
        let utxo = try Self.funding(account, amount: 100_000)
        let created = try spend(account, [utxo])
        #expect(throws: MuSig2AccountError.invalidSpend("input 1 is not an available coin of this account")) {
            _ = try review(account, created, [])
        }
        // Another account's coin claimed as ours fails the descriptor match.
        let other = try MuSig2Account(
            "tr(musig(\(try TestKeys.masters().suffix(2).map { try TestKeys.bareKeyExpression(master: $0) }.joined(separator: ",")))/<0;1>/*)",
            network: .signet)
        let foreign = try Self.funding(other, amount: 100_000)
        #expect(throws: MuSig2AccountError.scriptMismatch(index: 0, choice: 0)) { _ = try spend(account, [foreign]) }
        // The same outpoint known as the other account's coin: wrong script.
        #expect(throws: MuSig2AccountError.self) { _ = try review(account, created, [foreign]) }
    }

    @Test("an immature coinbase coin cannot pass review; a mature one can")
    func coinbaseMaturity() throws {
        let (account, _) = try Self.account()
        var utxo = try Self.funding(account, amount: 100_000, height: 1_000)
        utxo.isCoinbase = true
        let created = try spend(account, [utxo])
        let oneShort = utxo.height + Wallet.coinbaseMaturity - 2
        #expect(throws: MuSig2AccountError.invalidSpend("input 1 spends a coinbase that matures in 1 blocks")) {
            _ = try review(account, created, [utxo], chainTip: oneShort)
        }
        _ = try review(account, created, [utxo], chainTip: utxo.height + Wallet.coinbaseMaturity - 1)
    }

    /// One ceiling for creator and reviewer: a fee of exactly a tenth of the
    /// inputs passes, one satoshi more does not, and the creator never builds
    /// a proposal its reviewers would refuse.
    @Test("the fee ceiling admits one tenth of the inputs and refuses one satoshi more")
    func feeCeiling() throws {
        let (account, _) = try Self.account()
        let utxo = try Self.funding(account, amount: 100_000)
        do {
            _ = try spend(account, [utxo], feeRate: 100)
            Issue.record("expected the fee ceiling to refuse the spend")
        } catch let MuSig2AccountError.invalidSpend(message) {
            #expect(message.hasSuffix("exceeds the 10% safety limit for these inputs"))
        }
        let created = try spend(account, [utxo])
        let paymentIndex = try #require(created.outputs.firstIndex { $0.script == destination })
        let changeIndex = try #require(created.outputs.firstIndex { $0.script != destination })
        let ceiling = utxo.amount / 10
        var atCeiling = created
        atCeiling.outputs[paymentIndex].amount = utxo.amount - ceiling - 1
        atCeiling.outputs[changeIndex].amount = 1
        #expect(try review(account, atCeiling, [utxo]).fee == ceiling)
        var over = atCeiling
        over.outputs[paymentIndex].amount = utxo.amount - ceiling - 2
        #expect(throws: MuSig2AccountError.invalidSpend(
            "the \(ceiling + 1)-sat fee exceeds the 10% safety limit for these inputs")) {
            _ = try review(account, over, [utxo])
        }
    }

    // MARK: - Spending

    /// Every participant on its own device: round 1 and round 2 each run on a
    /// decoded copy, and the copies are combined in between. Two inputs at
    /// different coordinates prove the per-input contexts, and the last
    /// participant signs with only its account key.
    @Test("n-of-n spend: nonces, partial signatures, aggregate, valid key-path witnesses", arguments: [2, 3])
    func nOfNSpend(_ count: Int) throws {
        let (account, masters) = try Self.account(count)
        var signers = masters
        signers[count - 1] = try masters[count - 1].derived(path: "m/86'/1'/0'")
        let coins = [try Self.funding(account, amount: 60_000),
                     try Self.funding(account, amount: 40_000, chain: .change, index: 3, vout: 1)]
        let created = try account.createSpend(
            utxos: coins, payments: [Payment(amount: 90_000, scriptPubKey: destination)], changeIndex: 0,
            feeRateSatPerVByte: 2, chainTip: testChainTip, randomness: { 0.5 })
        #expect(created.inputs.count == 2)
        for input in created.inputs.indices {
            let coin = try #require(coins.first { $0.outpoint.vout == created.inputs[input].outputIndex })
            let context = try account.muSig2Context(choice: coin.chain.rawValue, index: coin.index)
            #expect(context.participants.count == count)
            #expect(created.inputs[input].musig2ParticipantPubKeys[context.aggregate] == context.participants)
            #expect(created.inputs[input].tapInternalKey == context.internalKey)
            #expect(coin.scriptPubKey == Data([0x51, 0x20]) + context.outputKey)
            let output = try Taproot.tweakedOutputKey(internalKey: context.internalKey, merkleRoot: nil)
            #expect(context.signingKey == Data([output.parity ? 0x03 : 0x02]) + output.key)
        }

        func decoded(_ psbt: PSBT) throws -> PSBT { try PSBT(base64: psbt.base64) }
        var secretNonces: [[Int: [Data: Data]]] = []
        var withNonces: [PSBT] = []
        for signer in signers {
            var copy = try decoded(created)
            secretNonces.append(try account.attachNonces(&copy, signingKey: signer, knownUTXOs: coins,
                                                         ownedOutputCoordinates: Self.changeCoordinates,
                                                         chainTip: testChainTip))
            withNonces.append(copy)
        }
        let nonced = try withNonces[0].combined(with: Array(withNonces.dropFirst()))
        #expect(nonced.inputs.allSatisfy { $0.musig2PubNonces.count == count })

        var partials: [PSBT] = []
        for (index, signer) in signers.enumerated() {
            var copy = try decoded(nonced)
            try account.sign(&copy, signingKey: signer, secretNonces: &secretNonces[index], knownUTXOs: coins,
                             ownedOutputCoordinates: Self.changeCoordinates, chainTip: testChainTip)
            #expect(secretNonces[index].values.flatMap(\.values).allSatisfy { $0.allSatisfy { $0 == 0 } },
                    "every secret nonce is consumed")
            // A second round 2 from the consumed nonces is refused.
            var again = try decoded(nonced)
            #expect(throws: MuSig.MuSig2Error.secnonceReused) {
                try account.sign(&again, signingKey: signer, secretNonces: &secretNonces[index], knownUTXOs: coins,
                                 ownedOutputCoordinates: Self.changeCoordinates, chainTip: testChainTip)
            }
            partials.append(copy)
        }
        var combined = try partials[0].combined(with: Array(partials.dropFirst()))
        try account.aggregate(&combined, knownUTXOs: coins, ownedOutputCoordinates: Self.changeCoordinates,
                              chainTip: testChainTip)
        let transaction = try account.finalizeSpend(&combined, knownUTXOs: coins,
                                                    ownedOutputCoordinates: Self.changeCoordinates,
                                                    chainTip: testChainTip)
        let spentOutputs = try combined.spentOutputs()
        for input in transaction.inputs.indices {
            #expect(transaction.inputs[input].witness.count == 1)
            let sighash = try SighashBIP341.sighash(tx: transaction, inputIndex: input,
                                                    spentOutputs: spentOutputs, hashType: .default)
            #expect(Secp256k1.Schnorr.verify(signature: transaction.inputs[input].witness[0], message: sighash,
                                             publicKey: Data(spentOutputs[input].scriptPubKey.dropFirst(2))))
        }
    }

    @Test("a non-participant gets no nonce, and a missing partial blocks aggregation")
    func nonParticipantAndMissingPartial() throws {
        let (account, masters) = try Self.account()
        let utxo = try Self.funding(account, amount: 80_000)
        var psbt = try spend(account, [utxo])
        let outsider = try TestKeys.masters()[2]
        #expect(throws: MuSig2AccountError.noParticipantKey(input: 0)) {
            _ = try account.attachNonces(&psbt, signingKey: outsider, knownUTXOs: [utxo],
                                         ownedOutputCoordinates: Self.changeCoordinates, chainTip: testChainTip)
        }
        var nonces = try masters.map { master in
            try account.attachNonces(&psbt, signingKey: master, knownUTXOs: [utxo],
                                     ownedOutputCoordinates: Self.changeCoordinates, chainTip: testChainTip)
        }
        // Round 2 after a restart, when the round-1 secret is gone, signs nothing.
        var forgotten: [Int: [Data: Data]] = [:]
        #expect(throws: MuSig2AccountError.missingNonce(input: 0)) {
            try account.sign(&psbt, signingKey: masters[0], secretNonces: &forgotten, knownUTXOs: [utxo],
                             ownedOutputCoordinates: Self.changeCoordinates, chainTip: testChainTip)
        }
        // Only one participant signs: aggregation refuses.
        try account.sign(&psbt, signingKey: masters[0], secretNonces: &nonces[0], knownUTXOs: [utxo],
                         ownedOutputCoordinates: Self.changeCoordinates, chainTip: testChainTip)
        #expect(throws: (any Error).self) {
            try account.aggregate(&psbt, knownUTXOs: [utxo], ownedOutputCoordinates: Self.changeCoordinates,
                                  chainTip: testChainTip)
        }
        #expect(psbt.inputs[0].tapKeySignature == nil)
    }

    @Test("the record keeps spent coins as tombstones and reads main's vault JSON keys")
    func recordCoding() throws {
        let (account, _) = try Self.account()
        var spent = try Self.funding(account, amount: 1_000, vout: 1)
        spent.spent = .init(spentBy: Data(repeating: 0x01, count: 32), height: 101)
        let record = MuSig2AccountRecord(id: account.id, name: "Shared", descriptor: account.descriptor.serialized(),
                                         createdAtHeight: 90, nextReceiveIndex: 2, nextChangeIndex: 1,
                                         allUtxos: [try Self.funding(account, amount: 5_000), spent])
        #expect(record.utxos.count == 1 && record.balance == 5_000)
        let json = try JSONEncoder().encode(record)
        let object = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        #expect(Set(object.keys) == ["id", "name", "descriptor", "createdAtHeight",
                                     "nextReceiveIndex", "nextChangeIndex", "utxos"])
        #expect(try JSONDecoder().decode(MuSig2AccountRecord.self, from: json) == record)
    }

    /// MuSig2 accounts travel under `vaults`, the key the shared-account
    /// Winnow and the first MuSig2 build used, so those backups restore here.
    /// MultisigAccountTests covers a bundle that mixes both kinds of account.
    @Test("bundles carry MuSig2 accounts under vaults")
    func bundleAccounts() throws {
        let (account, _) = try Self.account()
        let record = MuSig2AccountRecord(id: account.id, name: "Shared", descriptor: account.descriptor.serialized(),
                                         createdAtHeight: 90, nextReceiveIndex: 1,
                                         allUtxos: [try Self.funding(account, amount: 5_000)])
        var bundle = ImportBundle(network: "signet", lastKnownHeight: 200)
        #expect(!(try bundle.serialized()).contains("vaults"), "a bundle without accounts is unchanged")
        bundle.muSig2Accounts = [record]
        #expect(try bundle.serialized().contains("\"vaults\""))
        let decoded = try ImportBundle.decode(json: bundle.serialized())
        #expect(decoded.muSig2Accounts == [record])
        #expect(decoded.vaults == nil)

        var mainnet = bundle
        mainnet.network = "mainnet"
        #expect(throws: WalletError.unsupportedWalletData) { _ = try ImportBundle.decode(json: mainnet.serialized()) }
        bundle.muSig2Accounts = Array(repeating: record, count: ImportBundle.maximumVaults + 1)
        #expect(throws: WalletError.self) { _ = try ImportBundle.decode(json: bundle.serialized()) }
    }
}
