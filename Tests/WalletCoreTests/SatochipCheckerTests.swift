import Foundation
import NativeSecp256k1
import Testing
import TestSupport
@testable import WalletCore

/// The checker: from a PSBT and the account it registered, the same review
/// the phone runs, and approvals the card accepts only for that payment.
@Suite("Satochip checker")
struct SatochipCheckerTests {
    typealias Fixture = SatochipMuSig2AccountTests
    let destination = Data([0x51, 0x20] + repeatElement(0x77, count: 32))

    static func checker(_ setup: Fixture.Setup) throws -> Satochip.Checker {
        try Satochip.Checker(descriptor: setup.descriptor, network: .signet,
                             cardKey: setup.participant, twoFactorKey: Fixture.twoFactorKey, searchLimit: 50)
    }

    /// A spend with every participant's nonce attached, as the phone sends it to the checker.
    static func roundOne(_ setup: Fixture.Setup, coins: [WalletUTXO], payment: Payment) async throws
        -> (psbt: PSBT, phoneNonces: [Int: [Data: Data]], cardNonces: [Int: Satochip.CardNonce]) {
        var psbt = try setup.account.createSpend(utxos: coins, payments: [payment], changeIndex: 2,
                                                 feeRateSatPerVByte: 2, chainTip: testChainTip, randomness: { 0.5 })
        let owned = [MuSig2Account.OutputCoordinate(choice: AddressChain.change.rawValue, index: 2)]
        let phoneNonces = try setup.account.attachNonces(&psbt, signingKey: setup.phone, knownUTXOs: coins,
                                                         ownedOutputCoordinates: owned, chainTip: testChainTip)
        var session = try await Fixture.tap(setup)
        var cardNonces: [Int: Satochip.CardNonce] = [:]
        for request in try setup.account.cardNonceRequests(psbt, participant: setup.participant, knownUTXOs: coins,
                                                           ownedOutputCoordinates: owned, chainTip: testChainTip) {
            cardNonces[request.input] = try await session.generateNonce(aggregateKey: request.aggregateKey,
                                                                        message: request.message)
        }
        try setup.account.attachCardNonces(&psbt, participant: setup.participant,
                                           publicNonces: cardNonces.mapValues(\.publicNonce), knownUTXOs: coins)
        return (psbt, phoneNonces, cardNonces)
    }

    @Test("the checker reviews a spend from the PSBT alone and its approvals sign it")
    func reviewAndApprove() async throws {
        let setup = try await Fixture.setup()
        let checker = try Self.checker(setup)
        let coins = [try Fixture.coins(setup.account, count: 4, amount: 40_000)[3]]
        let (psbt, _, cardNonces) = try await Self.roundOne(setup, coins: coins,
                                                            payment: Payment(amount: 25_000, scriptPubKey: destination))

        let review = try checker.review(try PSBT(base64: psbt.base64))
        #expect(review.isReadyToApprove)
        #expect(review.inputs.map(\.index) == [3])
        #expect(review.inputs.map(\.amount) == [40_000])
        let external = try #require(review.outputs.first { !$0.isAccountOwned })
        #expect(external.amount == 25_000 && external.scriptPubKey == destination)
        let change = try #require(review.outputs.first { $0.isAccountOwned })
        #expect(change.scriptPubKey == (try setup.account.scriptPubKey(index: 2, choice: AddressChain.change.rawValue)))
        #expect(change.address == (try setup.account.address(index: 2, choice: AddressChain.change.rawValue)))
        #expect(review.fee == 40_000 - 25_000 - change.amount)
        #expect(review.sentAway == 25_000)

        let approvals = try checker.approve(psbt)
        #expect(approvals.txid == review.txid)
        var session = try await Fixture.tap(setup)
        let owned = [MuSig2Account.OutputCoordinate(choice: AddressChain.change.rawValue, index: 2)]
        for request in try setup.account.cardSignatureRequests(psbt, participant: setup.participant, knownUTXOs: coins,
                                                               ownedOutputCoordinates: owned, chainTip: testChainTip) {
            let partial = try await session.partialSign(
                encryptedSecretNonce: try #require(cardNonces[request.input]).encryptedSecretNonce,
                signingContext: request.signingContext, approval: approvals.byInput[request.input])
            #expect(partial.count == 32)
        }
    }

    /// The bar the design sets: a hacked phone that swaps the payment after
    /// the checker approved gets nothing from the card.
    @Test("approvals for one payment do not sign another")
    func approvalsBindThePayment() async throws {
        let setup = try await Fixture.setup()
        let checker = try Self.checker(setup)
        let coins = [try Fixture.coins(setup.account, count: 1, amount: 40_000)[0]]
        let approved = try await Self.roundOne(setup, coins: coins,
                                               payment: Payment(amount: 25_000, scriptPubKey: destination))
        let approvals = try checker.approve(approved.psbt)

        // The phone builds a different payment over the same coin and nonces.
        let thief = Data([0x51, 0x20] + repeatElement(0x66, count: 32))
        var swapped = try setup.account.createSpend(utxos: coins, payments: [Payment(amount: 25_000, scriptPubKey: thief)],
                                                    changeIndex: 2, feeRateSatPerVByte: 2, chainTip: testChainTip,
                                                    randomness: { 0.5 })
        swapped.inputs[0].musig2PubNonces = approved.psbt.inputs[0].musig2PubNonces
        let owned = [MuSig2Account.OutputCoordinate(choice: AddressChain.change.rawValue, index: 2)]
        let request = try #require(try setup.account.cardSignatureRequests(
            swapped, participant: setup.participant, knownUTXOs: coins, ownedOutputCoordinates: owned,
            chainTip: testChainTip).first)
        var session = try await Fixture.tap(setup)
        await #expect(throws: Satochip.SatochipError.approvalRefused) {
            _ = try await session.partialSign(encryptedSecretNonce: try #require(approved.cardNonces[0]).encryptedSecretNonce,
                                              signingContext: request.signingContext, approval: approvals.byInput[0])
        }
    }

    @Test("the checker refuses foreign coins, unfinished rounds and an unregistered card")
    func refusals() async throws {
        let setup = try await Fixture.setup()
        let checker = try Self.checker(setup)
        let coins = [try Fixture.coins(setup.account, count: 1, amount: 40_000)[0]]
        var psbt = try setup.account.createSpend(utxos: coins, payments: [Payment(amount: 25_000, scriptPubKey: destination)],
                                                 changeIndex: 0, feeRateSatPerVByte: 2, chainTip: testChainTip,
                                                 randomness: { 0.5 })
        #expect(!(try checker.review(psbt)).isReadyToApprove)
        #expect(throws: Satochip.Checker.CheckerError.incompleteRoundOne) { try checker.approve(psbt) }

        var foreign = psbt
        foreign.inputs[0].witnessUTXO = SighashBIP341.SpentOutput(amount: 40_000, scriptPubKey: destination)
        #expect(throws: Satochip.Checker.CheckerError.unknownInput(0)) { try checker.review(foreign) }
        psbt.inputs[0].witnessUTXO = nil
        #expect(throws: Satochip.Checker.CheckerError.missingInputAmount(0)) { try checker.review(psbt) }

        #expect(throws: Satochip.Checker.CheckerError.cardNotInAccount) {
            try Satochip.Checker(descriptor: setup.descriptor, network: .signet,
                                 cardKey: Data(repeating: 2, count: 33), twoFactorKey: Fixture.twoFactorKey)
        }
    }

    @Test("the checker's view of the card matches the key the phone read")
    func cardKeyExpression() async throws {
        let setup = try await Fixture.setup()
        let master = try HDKey(seed: Fixture.cardSeed)
        let account = try master.derived(path: Fixture.cardPath)
        let expression = try Satochip.Checker.cardKeyExpression(
            masterXpub: master.neutered.serialized(network: .testnet),
            accountXpub: account.neutered.serialized(network: .testnet), path: Fixture.cardPath, network: .testnet)
        #expect(expression == setup.cardKey.keyExpression(network: .testnet))
        #expect(throws: Satochip.SatochipError.self) {
            try Satochip.Checker.cardKeyExpression(masterXpub: account.neutered.serialized(network: .testnet),
                                                   accountXpub: account.neutered.serialized(network: .testnet),
                                                   path: Fixture.cardPath, network: .testnet)
        }
    }
}
