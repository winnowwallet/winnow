import Foundation
import Testing
import TestSupport
@testable import WalletCore

/// The sender's proposal checklist: BIP 78's own vectors accepted, and one
/// hostile proposal per rule refused, each built by the test receiver from
/// a real wallet send.
@Suite("Payjoin proposal checks (BIP 78 sender checklist)")
struct PayjoinProposalTests {
    // MARK: BIP 78 test vectors (P2SH-P2WPKH, 2 sat/vB, contribution 182 at output 0)

    static let originalBase64 = "cHNidP8BAHMCAAAAAY8nutGgJdyYGXWiBEb45Hoe9lWGbkxh/6bNiOJdCDuDAAAAAAD+////AtyVuAUAAAAAF6kUHehJ8GnSdBUOOv6ujXLrWmsJRDCHgIQeAAAAAAAXqRR3QJbbz0hnQ8IvQ0fptGn+votneofTAAAAAAEBIKgb1wUAAAAAF6kU3k4ekGHKWRNbA1rV5tR5kEVDVNCHAQcXFgAUx4pFclNVgo1WWAdN1SYNX8tphTABCGsCRzBEAiB8Q+A6dep+Rz92vhy26lT0AjZn4PRLi8Bf9qoB/CMk0wIgP/Rj2PWZ3gEjUkTlhDRNAQ0gXwTO7t9n+V14pZ6oljUBIQMVmsAaoNWHVMS02LfTSe0e388LNitPa1UQZyOihY+FFgABABYAFEb2Giu6c4KO5YW0pfw3lGp9jMUUAAA="
    static let proposalBase64 = "cHNidP8BAJwCAAAAAo8nutGgJdyYGXWiBEb45Hoe9lWGbkxh/6bNiOJdCDuDAAAAAAD+////jye60aAl3JgZdaIERvjkeh72VYZuTGH/ps2I4l0IO4MBAAAAAP7///8CJpW4BQAAAAAXqRQd6EnwadJ0FQ46/q6NcutaawlEMIcACT0AAAAAABepFHdAltvPSGdDwi9DR+m0af6+i2d6h9MAAAAAAQEgqBvXBQAAAAAXqRTeTh6QYcpZE1sDWtXm1HmQRUNU0IcAAQEggIQeAAAAAAAXqRTI8sv5ymFHLIjkZNRrNXSEXZHY1YcBBxcWABRfgGZV5ZJMkgTC1RvlOU9L+e2iEAEIawJHMEQCIGe7e0DfJaVPRYEKWxddL2Pr0G37BoKz0lyNa02O2/tWAiB7ZVgBoF4s8MHocYWWmo4Q1cyV2wl7MX0azlqa8NBENAEhAmXWPPW0G3yE3HajBOb7gO7iKzHSmZ0o0w0iONowcV+tAAAA"
    static let proposalWithSenderInfoBase64 = "cHNidP8BAJwCAAAAAo8nutGgJdyYGXWiBEb45Hoe9lWGbkxh/6bNiOJdCDuDAAAAAAD+////jye60aAl3JgZdaIERvjkeh72VYZuTGH/ps2I4l0IO4MBAAAAAP7///8CJpW4BQAAAAAXqRQd6EnwadJ0FQ46/q6NcutaawlEMIcACT0AAAAAABepFHdAltvPSGdDwi9DR+m0af6+i2d6h9MAAAAAAQEgqBvXBQAAAAAXqRTeTh6QYcpZE1sDWtXm1HmQRUNU0IcBBBYAFMeKRXJTVYKNVlgHTdUmDV/LaYUwIgYDFZrAGqDVh1TEtNi300ntHt/PCzYrT2tVEGcjooWPhRYYSFzWUDEAAIABAACAAAAAgAEAAAAAAAAAAAEBIICEHgAAAAAAF6kUyPLL+cphRyyI5GTUazV0hF2R2NWHAQcXFgAUX4BmVeWSTJIEwtUb5TlPS/ntohABCGsCRzBEAiBnu3tA3yWlT0WBClsXXS9j69Bt+waCs9JcjWtNjtv7VgIge2VYAaBeLPDB6HGFlpqOENXMldsJezF9Gs5amvDQRDQBIQJl1jz1tBt8hNx2owTm+4Du4isx0pmdKNMNIjjaMHFfrQABABYAFEb2Giu6c4KO5YW0pfw3lGp9jMUUIgICygvBWB5prpfx61y1HDAwo37kYP3YRJBvAjtunBAur3wYSFzWUDEAAIABAACAAAAAgAEAAAABAAAAAAA="

    private static func vectorContext() throws -> PayjoinContext {
        let original = try PSBT(base64: originalBase64)
        let tx = try original.extractedTransaction()
        return try PayjoinContext(original: original, payeeScript: tx.outputs[1].scriptPubKey,
                                  payeeAmount: tx.outputs[1].value, feeOutputIndex: 0, maxFeeContribution: 182,
                                  minFeeRateSatPerVByte: 2)
    }

    @Test("the BIP 78 original is read as the vector describes it")
    func vectorOriginal() throws {
        let context = try Self.vectorContext()
        #expect(try context.originalFee() == 332)
        #expect(abs((try context.originalFeeRate()) - 2) < 0.01)
        #expect(context.senderParameters == "v=2&disableoutputsubstitution=true&additionalfeeoutputindex=0&maxadditionalfeecontribution=182&minfeerate=2")
        let body = String(decoding: try context.messageBody(), as: UTF8.self)
        #expect(body.hasPrefix("cHNidP8BAHMCAAAAAY8nutGgJdyYGXWiBEb45Hoe"))
        #expect(body.contains("\nv=2&"))
    }

    @Test("the BIP 78 proposal is accepted: contribution 182, receiver input counted, fee facts right")
    func vectorProposal() throws {
        let context = try Self.vectorContext()
        let checked = try context.check(proposal: try PSBT(base64: Self.proposalBase64))
        #expect(checked.senderInputIndices == [0])
        #expect(checked.receiverInputCount == 1)
        #expect(checked.contributedFee == 182)
        #expect(checked.originalFee == 332)
        #expect(checked.proposedFee == 514)
        #expect(checked.senderSpend == 2_000_000 + 332 + 182)
        // The sender's input got its UTXO and sighash type back for signing.
        #expect(checked.psbt.inputs[0].witnessUTXO?.amount == 97_983_400)
        #expect(checked.psbt.inputs[0].sighashType == 0)
        // The receiver's finalized P2SH-P2WPKH input carries a scriptSig and a witness.
        #expect(checked.psbt.inputs[1].finalScriptSig != nil)
        #expect(checked.psbt.inputs[1].finalScriptWitness?.count == 2)
    }

    @Test("the vector proposal 'filled with sender information' is refused for its key paths")
    func vectorProposalWithKeyPaths() throws {
        let context = try Self.vectorContext()
        #expect(throws: PayjoinProposalError.inputCarriesKeyPaths(0)) {
            try context.check(proposal: try PSBT(base64: Self.proposalWithSenderInfoBase64))
        }
    }

    @Test("a contribution of 183 or a 1-sat fee decrease on the vector is refused")
    func vectorBounds() throws {
        let original = try PSBT(base64: Self.originalBase64)
        let tx = try original.extractedTransaction()
        let tighter = try PayjoinContext(original: original, payeeScript: tx.outputs[1].scriptPubKey,
                                         payeeAmount: tx.outputs[1].value, feeOutputIndex: 0, maxFeeContribution: 181,
                                         minFeeRateSatPerVByte: 0)
        #expect(throws: PayjoinProposalError.feeContributionExceedsMaximum(contributed: 182, maximum: 181)) {
            try tighter.check(proposal: try PSBT(base64: Self.proposalBase64))
        }
        // No contribution agreed at all: the change may not move.
        let none = try PayjoinContext(original: original, payeeScript: tx.outputs[1].scriptPubKey,
                                      payeeAmount: tx.outputs[1].value, feeOutputIndex: nil, maxFeeContribution: 0,
                                      minFeeRateSatPerVByte: 0)
        #expect(throws: PayjoinProposalError.senderOutputReduced(0)) {
            try none.check(proposal: try PSBT(base64: Self.proposalBase64))
        }
    }

    // MARK: Hostile proposals from a wallet send

    private struct Fixture {
        var wallet: Wallet
        var prepared: Wallet.PreparedSend
        var context: PayjoinContext
        var receiver: FakePayjoinReceiver
        var parameters: [String: String]
    }

    /// Two coins that both have to go in, so the sender has two inputs.
    static let paymentAmount: Int64 = 300_000

    private static func fixture(coins: [Int64] = [200_000, 150_000]) async throws -> Fixture {
        let directory = try FakePayjoinDirectory()
        let receiver = try FakePayjoinReceiver(network: .signet, directory: directory)
        receiver.fund(outpoint: Transaction.Outpoint(txid: Data(repeating: 0x77, count: 32), vout: 3), amount: 90_000)
        let (wallet, _) = try await fundedWallet(coins: coins.enumerated().map { (.receive, UInt32($0.offset), $0.element, 100) })
        let payee = Payment(amount: paymentAmount, scriptPubKey: receiver.paymentScript)
        let prepared = try await wallet.buildSend(payments: [payee], feeRateSatPerVByte: 2, chainTip: testChainTip,
                                                  randomness: { 0.5 })
        let context = try await wallet.payjoinContext(for: prepared, payee: payee, feeRateSatPerVByte: 2)
        var parameters: [String: String] = [:]
        for pair in context.senderParameters.split(separator: "&") {
            let parts = pair.split(separator: "=")
            parameters[String(parts[0])] = String(parts[1])
        }
        return Fixture(wallet: wallet, prepared: prepared, context: context, receiver: receiver, parameters: parameters)
    }

    @Test("an honest proposal is accepted, signed only on our inputs, and pays at least the agreed rate")
    func honest() async throws {
        let fixture = try await Self.fixture()
        #expect(fixture.context.maxFeeContribution == 220, "2 sat/vB × 110 vB")
        #expect(fixture.prepared.built.transaction.inputs.count == 2)
        let proposal = try fixture.receiver.buildProposal(original: fixture.prepared.built.psbt,
                                                          parameters: fixture.parameters, behaviour: .honest)
        let checked = try fixture.context.check(proposal: proposal)
        #expect(checked.receiverInputCount == 1)
        #expect(checked.senderInputIndices.count == fixture.prepared.built.transaction.inputs.count)
        #expect(checked.contributedFee > 0 && checked.contributedFee <= 220)
        let signed = try await fixture.wallet.signPayjoinProposal(checked, prepared: fixture.prepared)
        #expect(signed.inputs.count == fixture.prepared.built.transaction.inputs.count + 1)
        #expect(signed.inputs.allSatisfy { $0.witness.count == 1 && $0.witness[0].count == 64 })
        #expect(signed.outputs.contains { $0.scriptPubKey == fixture.receiver.paymentScript && $0.value >= Self.paymentAmount })
        try checked.verifyFeeRate(of: signed)
        // The original went to the receiver stripped of key material.
        let stripped = try PSBT(base64: fixture.prepared.built.psbt.strippedForPayjoin().base64V0())
        #expect(stripped.inputs.allSatisfy { $0.tapInternalKey == nil && !$0.carriesKeyPaths && $0.isFinalized })
        #expect(stripped.outputs.allSatisfy { !$0.carriesKeyPaths && $0.tapInternalKey == nil })
    }

    @Test("an echoed original (no receiver input) is accepted as a plain payment")
    func echo() async throws {
        let fixture = try await Self.fixture()
        let proposal = try fixture.receiver.buildProposal(original: fixture.prepared.built.psbt,
                                                          parameters: fixture.parameters, behaviour: .echo)
        let checked = try fixture.context.check(proposal: proposal)
        #expect(checked.receiverInputCount == 0)
        #expect(checked.contributedFee == 0)
        let signed = try await fixture.wallet.signPayjoinProposal(checked, prepared: fixture.prepared)
        #expect(signed.txid == fixture.prepared.built.transaction.txid)
    }

    @Test("each hostile proposal is refused by the rule it breaks", arguments: [
        (FakePayjoinReceiver.Behaviour.stealChange, PayjoinProposalError.feeContributionExceedsMaximum(contributed: 1_220, maximum: 220)),
        (.reducePayment, .paymentOutputChanged),
        (.redirectPayment, .senderOutputsMissingOrShuffled),
        (.swapSenderInput, .senderInputsMissingOrShuffled),
        (.dropSenderInput, .senderInputsMissingOrShuffled),
        (.duplicateSenderInput, .duplicateInput),
        (.decreaseFee, .absoluteFeeDecreased(original: 0, proposed: 0)),
        (.overchargeForInput, .contributionExceedsAddedInputs(contributed: 0, allowed: 0)),
        (.unfinalizedInput, .receiverInputNotFinalized(1)),
        (.leaveKeyPaths, .inputCarriesKeyPaths(0)),
        (.changeSequence, .senderInputSequenceChanged(0)),
        (.changeLocktime, .locktimeChanged),
    ])
    func hostile(behaviour: FakePayjoinReceiver.Behaviour, expected: PayjoinProposalError) async throws {
        let fixture = try await Self.fixture()
        let proposal = try fixture.receiver.buildProposal(original: fixture.prepared.built.psbt,
                                                          parameters: fixture.parameters, behaviour: behaviour)
        do {
            _ = try fixture.context.check(proposal: proposal)
            Issue.record("\(behaviour) was accepted")
        } catch let error as PayjoinProposalError {
            switch (error, expected) {
            case (.absoluteFeeDecreased, .absoluteFeeDecreased), (.contributionExceedsAddedInputs, .contributionExceedsAddedInputs):
                break
            default:
                #expect(error == expected, "\(behaviour)")
            }
        }
    }

    @Test("a proposal that adds an input without fee passes the checks and fails the floor once signed")
    func feeFloorAfterSigning() async throws {
        let fixture = try await Self.fixture()
        let proposal = try fixture.receiver.buildProposal(original: fixture.prepared.built.psbt,
                                                          parameters: fixture.parameters, behaviour: .underpayFeeRate)
        let checked = try fixture.context.check(proposal: proposal)
        #expect(checked.contributedFee == 0)
        #expect(checked.proposedFee == checked.originalFee)
        await #expect(throws: PayjoinProposalError.self) {
            try await fixture.wallet.signPayjoinProposal(checked, prepared: fixture.prepared)
        }
    }

    @Test("a sender input pre-finalized by the receiver, or signed with another sighash type, is refused")
    func senderInputTampering() async throws {
        let fixture = try await Self.fixture()
        var proposal = try fixture.receiver.buildProposal(original: fixture.prepared.built.psbt,
                                                          parameters: fixture.parameters, behaviour: .honest)
        proposal.inputs[0].finalScriptWitness = [Data(count: 64)]
        #expect(throws: PayjoinProposalError.senderInputAlreadyFinalized(0)) { try fixture.context.check(proposal: proposal) }
        proposal.inputs[0].finalScriptWitness = nil
        proposal.inputs[0].sighashType = 0x83
        #expect(throws: PayjoinProposalError.senderInputSighashType(0)) { try fixture.context.check(proposal: proposal) }
        proposal.inputs[0].sighashType = nil
        proposal.inputs[0].tapKeySignature = Data(count: 64)
        #expect(throws: PayjoinProposalError.inputCarriesPartialSignatures(0)) { try fixture.context.check(proposal: proposal) }
    }

    @Test("a receiver input that only names a wrong previous transaction has no usable UTXO")
    func receiverUTXOLie() async throws {
        let fixture = try await Self.fixture()
        var proposal = try fixture.receiver.buildProposal(original: fixture.prepared.built.psbt,
                                                          parameters: fixture.parameters, behaviour: .honest)
        // Swap the receiver input's witness UTXO for a non-witness UTXO whose txid does not match.
        let other = Transaction(version: 2, inputs: [coinbaseInput()],
                                outputs: [Transaction.Output(value: 90_000, scriptPubKey: fixture.receiver.paymentScript)],
                                locktime: 0)
        proposal.inputs[1].witnessUTXO = nil
        proposal.inputs[1].pairs.append(PSBT.KeyValue(type: 0x00, value: other.serialized(includeWitness: false)))
        #expect(throws: PayjoinProposalError.receiverInputMissingUTXO(1)) { try fixture.context.check(proposal: proposal) }
    }

    @Test("the money invariant: the sender never spends more than amount, fee and contribution")
    func senderSpend() async throws {
        let fixture = try await Self.fixture()
        let proposal = try fixture.receiver.buildProposal(original: fixture.prepared.built.psbt,
                                                          parameters: fixture.parameters, behaviour: .honest)
        let checked = try fixture.context.check(proposal: proposal)
        #expect(checked.senderSpend <= Self.paymentAmount + fixture.prepared.fee + fixture.context.maxFeeContribution)
        #expect(checked.senderSpend == Self.paymentAmount + fixture.prepared.fee + checked.contributedFee)
    }

    @Test("a context refuses an original that does not pay the payee exactly once")
    func contextValidation() async throws {
        let fixture = try await Self.fixture()
        #expect(throws: PayjoinProposalError.malformed("original must pay the payee exactly once")) {
            try PayjoinContext(original: fixture.prepared.built.psbt, payeeScript: Data([0x51, 0x20] + Data(count: 32)),
                               payeeAmount: 1, feeOutputIndex: nil, maxFeeContribution: 0, minFeeRateSatPerVByte: 1)
        }
    }
}
