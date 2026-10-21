import Foundation
import NativeSecp256k1
import Testing
import TestSupport
@testable import WalletCore

/// A raw MuSig2 account between this phone and a Satochip card (modelled by
/// `SatochipEmulator`): the card's key read with its origin, both rounds over
/// card sessions, the checker's approvals as pasted text, and a spend whose
/// key-path witnesses verify.
@Suite("Satochip MuSig2 account")
struct SatochipMuSig2AccountTests {
    static let pin = Data("1234".utf8)
    static let cardSeed = Data(repeating: 0x2C, count: 32)
    static let twoFactorKey = Data(hex: "00112233445566778899aabbccddeeff01234567")!
    static let cardPath: [UInt32] = [86 + HDKey.hardenedOffset, 1 + HDKey.hardenedOffset, HDKey.hardenedOffset]
    static let changeCoordinates = [MuSig2Account.OutputCoordinate(choice: AddressChain.change.rawValue, index: 0)]
    let destination = Data([0x51, 0x20] + repeatElement(0x77, count: 32))

    struct Setup {
        let account: MuSig2Account
        let phone: HDKey
        let card: SatochipEmulator
        let cardKey: Satochip.ParticipantKey
        var participant: Data { cardKey.accountKey.publicKey }
    }

    /// The phone's key and the card's, read from the card, in one account.
    static func setup(twoFactorKey: Data? = Self.twoFactorKey) async throws -> Setup {
        let phone = try TestKeys.master(entropyByte: 0xA1)
        let card = SatochipEmulator(pin: pin, seed: cardSeed, twoFactorKey: twoFactorKey)
        var session = Satochip.Session(transport: card)
        try await session.connect(pin: pin)
        let cardKey = try await session.participantKey(path: cardPath)
        let descriptor = "tr(musig(\(try TestKeys.bareKeyExpression(master: phone)),"
            + "\(cardKey.keyExpression(network: .testnet)))/<0;1>/*)"
        return Setup(account: try MuSig2Account(descriptor, network: .signet), phone: phone, card: card,
                     cardKey: cardKey)
    }

    /// One tap: connect and derive the card's participant key.
    static func tap(_ setup: Setup) async throws -> Satochip.Session {
        var session = Satochip.Session(transport: setup.card)
        try await session.connect(pin: pin)
        try await session.derive(path: setup.cardKey.path)
        return session
    }

    static func coins(_ account: MuSig2Account, count: Int, amount: Int64) throws -> [WalletUTXO] {
        try (0 ..< count).map { index in
            try WalletUTXO(txid: Data(repeating: 0x5A, count: 32), vout: UInt32(index), amount: amount,
                           scriptPubKey: account.scriptPubKey(index: UInt32(index), choice: AddressChain.receive.rawValue),
                           chain: .receive, index: UInt32(index), height: 100)
        }
    }

    @Test("the phone and the card complete a 2-of-2 spend, the card under its checker's approvals")
    func phoneAndCardSpend() async throws {
        let setup = try await Self.setup()
        let account = setup.account
        let coins = try Self.coins(account, count: 2, amount: 60_000)
        var psbt = try account.createSpend(utxos: coins, payments: [Payment(amount: 90_000, scriptPubKey: destination)],
                                           changeIndex: 0, feeRateSatPerVByte: 2, chainTip: testChainTip,
                                           randomness: { 0.5 })
        #expect(psbt.inputs.count == 2)

        // Round 1: the phone's nonces, then one tap for the card's.
        var phoneNonces = try account.attachNonces(&psbt, signingKey: setup.phone, knownUTXOs: coins,
                                                   ownedOutputCoordinates: Self.changeCoordinates,
                                                   chainTip: testChainTip)
        var session = try await Self.tap(setup)
        var cardNonces: [Int: Satochip.CardNonce] = [:]
        for request in try account.cardNonceRequests(psbt, participant: setup.participant, knownUTXOs: coins,
                                                     ownedOutputCoordinates: Self.changeCoordinates,
                                                     chainTip: testChainTip) {
            cardNonces[request.input] = try await session.generateNonce(aggregateKey: request.aggregateKey,
                                                                        message: request.message)
        }
        try account.attachCardNonces(&psbt, participant: setup.participant,
                                     publicNonces: cardNonces.mapValues(\.publicNonce), knownUTXOs: coins)
        psbt = try PSBT(base64: psbt.base64) // the PSBT travels as text between rounds
        #expect(psbt.inputs.allSatisfy { $0.musig2PubNonces.count == 2 })

        // The checker approves each context; the phone gets the approvals as text.
        let requests = try account.cardSignatureRequests(psbt, participant: setup.participant, knownUTXOs: coins,
                                                         ownedOutputCoordinates: Self.changeCoordinates,
                                                         chainTip: testChainTip)
        var byInput: [Int: Data] = [:]
        for request in requests {
            byInput[request.input] = try Satochip.twoFactorApproval(signingContext: request.signingContext,
                                                                    key: Self.twoFactorKey)
        }
        let txid = try psbt.unsignedTransaction().txid.displayHex
        let approvals = try Satochip.Approvals(text: Satochip.Approvals(txid: txid, byInput: byInput).text)
        #expect(approvals.txid == txid)

        // Round 2: a second tap for the card's partial signatures, then the phone's.
        session = try await Self.tap(setup)
        var partials: [Int: Data] = [:]
        for request in requests {
            partials[request.input] = try await session.partialSign(
                encryptedSecretNonce: try #require(cardNonces[request.input]).encryptedSecretNonce,
                signingContext: request.signingContext, approval: approvals.byInput[request.input])
        }
        try account.attachCardPartialSignatures(&psbt, participant: setup.participant, partialSignatures: partials,
                                                knownUTXOs: coins, ownedOutputCoordinates: Self.changeCoordinates,
                                                chainTip: testChainTip)
        try account.sign(&psbt, signingKey: setup.phone, secretNonces: &phoneNonces, knownUTXOs: coins,
                         ownedOutputCoordinates: Self.changeCoordinates, chainTip: testChainTip)
        try account.aggregate(&psbt, knownUTXOs: coins, ownedOutputCoordinates: Self.changeCoordinates,
                              chainTip: testChainTip)
        let transaction = try account.finalizeSpend(&psbt, knownUTXOs: coins,
                                                    ownedOutputCoordinates: Self.changeCoordinates,
                                                    chainTip: testChainTip)
        let spentOutputs = try psbt.spentOutputs()
        for input in transaction.inputs.indices {
            #expect(transaction.inputs[input].witness.count == 1)
            let sighash = try SighashBIP341.sighash(tx: transaction, inputIndex: input, spentOutputs: spentOutputs,
                                                    hashType: .default)
            #expect(Secp256k1.Schnorr.verify(signature: transaction.inputs[input].witness[0], message: sighash,
                                             publicKey: Data(spentOutputs[input].scriptPubKey.dropFirst(2))))
        }
    }

    @Test("a card partial signature that does not verify never reaches the PSBT")
    func badPartialRefused() async throws {
        let setup = try await Self.setup(twoFactorKey: nil)
        let account = setup.account
        let coins = try Self.coins(account, count: 1, amount: 100_000)
        var psbt = try account.createSpend(utxos: coins, payments: [Payment(amount: 50_000, scriptPubKey: destination)],
                                           changeIndex: 0, feeRateSatPerVByte: 2, chainTip: testChainTip,
                                           randomness: { 0.5 })
        _ = try account.attachNonces(&psbt, signingKey: setup.phone, knownUTXOs: coins,
                                     ownedOutputCoordinates: Self.changeCoordinates, chainTip: testChainTip)
        var session = try await Self.tap(setup)
        let request = try #require(try account.cardNonceRequests(
            psbt, participant: setup.participant, knownUTXOs: coins, ownedOutputCoordinates: Self.changeCoordinates,
            chainTip: testChainTip).first)
        let nonce = try await session.generateNonce(aggregateKey: request.aggregateKey, message: request.message)
        try account.attachCardNonces(&psbt, participant: setup.participant, publicNonces: [0: nonce.publicNonce],
                                     knownUTXOs: coins)
        let context = try #require(try account.cardSignatureRequests(
            psbt, participant: setup.participant, knownUTXOs: coins, ownedOutputCoordinates: Self.changeCoordinates,
            chainTip: testChainTip).first).signingContext
        var partial = try await session.partialSign(encryptedSecretNonce: nonce.encryptedSecretNonce,
                                                    signingContext: context, approval: nil)
        partial[partial.startIndex + 31] ^= 0x01
        #expect(throws: PSBTError.self) {
            try account.attachCardPartialSignatures(&psbt, participant: setup.participant, partialSignatures: [0: partial],
                                                    knownUTXOs: coins, ownedOutputCoordinates: Self.changeCoordinates,
                                                    chainTip: testChainTip)
        }
        #expect(psbt.inputs[0].musig2PartialSigs.isEmpty)
    }

    @Test("a card is asked for at most sixteen inputs")
    func sixteenInputs() async throws {
        let setup = try await Self.setup()
        let account = setup.account
        for (count, allowed) in [(16, true), (17, false)] {
            let coins = try Self.coins(account, count: count, amount: 20_000)
            let psbt = try account.createSpend(utxos: coins,
                                               payments: [Payment(amount: Int64(count) * 20_000 - 20_000,
                                                                  scriptPubKey: destination)],
                                               changeIndex: 0, feeRateSatPerVByte: 2, chainTip: testChainTip,
                                               randomness: { 0.5 })
            #expect(psbt.inputs.count == count)
            let requests = Result {
                try account.cardNonceRequests(psbt, participant: setup.participant, knownUTXOs: coins,
                                              ownedOutputCoordinates: Self.changeCoordinates, chainTip: testChainTip)
            }
            if allowed {
                #expect(try requests.get().count == count)
            } else {
                #expect(throws: MuSig2AccountError.self) { try requests.get() }
            }
        }
    }

    @Test("the card's participant is found in the descriptor by its account key")
    func participantLookup() async throws {
        let setup = try await Self.setup()
        let single = try #require(setup.account.participant(forCardKey: setup.participant))
        #expect(single.origin?.fingerprint == setup.cardKey.masterFingerprint)
        #expect(setup.account.participant(forCardKey: Data(repeating: 2, count: 33)) == nil)
    }

    @Test("approvals text round-trips and refuses anything else")
    func approvalsText() throws {
        let approval = Satochip.twoFactorFlag + Data(repeating: 0xAB, count: 20)
        let txid = String(repeating: "ab", count: 32)
        let approvals = Satochip.Approvals(txid: txid, byInput: [0: approval, 3: approval])
        #expect(approvals.text == "winnow-satochip-approvals 1 \(txid)\n0 \(approval.hex)\n3 \(approval.hex)")
        #expect(try Satochip.Approvals(text: "  \n" + approvals.text + "\n") == approvals)
        for junk in ["", "hello", "winnow-satochip-approvals 1 \(txid)",
                     "winnow-satochip-approvals 2 \(txid)\n0 \(approval.hex)",
                     "winnow-satochip-approvals 1 \(txid)\n0 \(approval.hex)\n0 \(approval.hex)",
                     "winnow-satochip-approvals 1 \(txid)\n-1 \(approval.hex)",
                     "winnow-satochip-approvals 1 \(txid)\n0 \(Data(repeating: 0xAB, count: 22).hex)",
                     "winnow-satochip-approvals 1 abcd\n0 \(approval.hex)"] {
            #expect(throws: Satochip.SatochipError.self) { try Satochip.Approvals(text: junk) }
        }
    }
}
