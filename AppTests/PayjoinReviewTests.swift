@testable import WinnowApp
import WalletCore
import TestSupport
import XCTest

/// `SendPreview.authorizes(payjoinProposal:)`, the gate between a checked
/// proposal and our signatures, mutated one authorization-relevant fact at
/// a time (the shape of `SendPreviewAuthorizationTests`); and the relay
/// setting's resolution per network.
@MainActor
final class PayjoinReviewTests: XCTestCase {
    private let recipientScript = Data([0x51, 0x20] + repeatElement(0xAA, count: 32))
    private let changeScript = Data([0x51, 0x20] + repeatElement(0xBB, count: 32))
    private let receiverScript = Data([0x51, 0x20] + repeatElement(0xCC, count: 32))
    private let txidA = Data(repeating: 0x11, count: 32)
    private let txidB = Data(repeating: 0x22, count: 32)
    private let txidR = Data(repeating: 0x33, count: 32)

    private func preview(contribution: Int64 = 200) async throws -> AppModel.SendPreview {
        let directory = try FakePayjoinDirectory()
        let receiver = try FakePayjoinReceiver(network: .signet, directory: directory)
        return AppModel.SendPreview(
            destination: "tb1p-recipient",
            payments: [Payment(amount: 50_000, scriptPubKey: recipientScript)],
            feeRateSatPerVByte: 2, fee: 1_000, changeAmount: 40_000, inputCount: 2,
            selectedOutpoints: [.init(txid: txidA, vout: 0), .init(txid: txidB, vout: 1)],
            change: Payment(amount: 40_000, scriptPubKey: changeScript),
            payjoin: .init(parameters: await receiver.parameters(), relay: URL(string: "https://relay.example")!,
                           maxFeeContribution: contribution, required: false))
    }

    /// A checked proposal shaped like an honest receiver's answer: our two
    /// inputs in order, the receiver's at the end, payment raised, change
    /// down by the contribution.
    private func proposal(inputs: [(Data, UInt32)]? = nil, outputs: [(Data, Int64)]? = nil,
                          senderIndices: [Int] = [0, 1], contributed: Int64 = 150, proposedFee: Int64 = 1_150,
                          senderSpend: Int64 = 51_150) throws -> CheckedProposal {
        let txInputs = (inputs ?? [(txidA, 0), (txidB, 1), (txidR, 0)]).map {
            Transaction.Input(previousOutput: .init(txid: $0.0, vout: $0.1), scriptSig: Data(), sequence: 0xFFFF_FFFD)
        }
        let txOutputs = (outputs ?? [(recipientScript, 80_000), (changeScript, 39_850)]).map {
            Transaction.Output(value: $0.1, scriptPubKey: $0.0)
        }
        let tx = Transaction(version: 2, inputs: txInputs, outputs: txOutputs, locktime: 0)
        let psbt = try PSBT(unsignedTx: tx, inputs: txInputs.map { _ in
            PSBT.InputInfo(spentOutput: .init(amount: 50_000, scriptPubKey: changeScript))
        }, outputs: txOutputs.map { _ in PSBT.OutputInfo() })
        return CheckedProposal(psbt: psbt, senderInputIndices: senderIndices, receiverInputCount: 1,
                               contributedFee: contributed, proposedFee: proposedFee, originalFee: 1_000,
                               minFeeRateSatPerVByte: 2, senderSpend: senderSpend)
    }

    func testHonestProposalIsAuthorized() async throws {
        let preview = try await preview()
        XCTAssertTrue(try preview.authorizes(payjoinProposal: proposal()))
    }

    func testOurInputsMustBeExactlyTheReviewedOnesInOrder() async throws {
        let preview = try await preview()
        XCTAssertFalse(try preview.authorizes(payjoinProposal: proposal(inputs: [(txidB, 1), (txidA, 0), (txidR, 0)])))
        XCTAssertFalse(try preview.authorizes(payjoinProposal: proposal(inputs: [(txidA, 0), (txidR, 0)], senderIndices: [0])))
        XCTAssertFalse(try preview.authorizes(payjoinProposal: proposal(inputs: [(txidA, 0), (txidA, 1), (txidR, 0)])))
        // A third sender input the review never saw.
        XCTAssertFalse(try preview.authorizes(payjoinProposal: proposal(inputs: [(txidA, 0), (txidB, 1), (txidR, 0)],
                                                                        senderIndices: [0, 1, 2])))
    }

    func testPaymentOutputKeepsScriptAndAtLeastAmount() async throws {
        let preview = try await preview()
        XCTAssertFalse(try preview.authorizes(payjoinProposal: proposal(outputs: [(recipientScript, 49_999), (changeScript, 39_850)])))
        XCTAssertFalse(try preview.authorizes(payjoinProposal: proposal(outputs: [(receiverScript, 80_000), (changeScript, 39_850)])))
        XCTAssertTrue(try preview.authorizes(payjoinProposal: proposal(outputs: [(recipientScript, 50_000), (changeScript, 39_850)])))
    }

    func testChangeMayDropByAtMostTheContribution() async throws {
        let preview = try await preview()
        XCTAssertTrue(try preview.authorizes(payjoinProposal: proposal(outputs: [(recipientScript, 80_000), (changeScript, 39_800)])))
        XCTAssertFalse(try preview.authorizes(payjoinProposal: proposal(outputs: [(recipientScript, 80_000), (changeScript, 39_799)])))
        XCTAssertFalse(try preview.authorizes(payjoinProposal: proposal(outputs: [(recipientScript, 80_000)])))
        XCTAssertFalse(try preview.authorizes(payjoinProposal: proposal(outputs: [(recipientScript, 80_000), (receiverScript, 39_850)])))
    }

    func testFeeAndSpendBounds() async throws {
        let preview = try await preview()
        XCTAssertFalse(try preview.authorizes(payjoinProposal: proposal(contributed: 201)))
        XCTAssertFalse(try preview.authorizes(payjoinProposal: proposal(proposedFee: 999)))
        XCTAssertFalse(try preview.authorizes(payjoinProposal: proposal(senderSpend: 51_201)))
        XCTAssertTrue(try preview.authorizes(payjoinProposal: proposal(senderSpend: 51_200)))
    }

    func testPreviewWithoutPayjoinOrWithSilentPaymentsAuthorizesNothing() async throws {
        var preview = try await preview()
        let checked = try proposal()
        preview.payjoin = nil
        XCTAssertFalse(preview.authorizes(payjoinProposal: checked))
        preview = try await self.preview()
        preview.silentPayments = [try SilentPayment(amount: 1, address: SilentPaymentTestReceiver(network: .signet).code,
                                                     network: .signet)]
        XCTAssertFalse(preview.authorizes(payjoinProposal: checked))
    }

    // MARK: Relay setting

    func testRelayResolvesPerNetworkAndRefusesPlaintextOffDevice() {
        XCTAssertEqual(AppModel.payjoinRelayURL(custom: "", network: .mainnet)?.absoluteString, "https://payjoin.achow101.com")
        XCTAssertEqual(AppModel.payjoinRelayURL(custom: "", network: .signet)?.absoluteString, "https://payjoin.achow101.com")
        XCTAssertNil(AppModel.payjoinRelayURL(custom: "", network: .regtest))
        XCTAssertEqual(AppModel.payjoinRelayURL(custom: "https://pj.example/", network: .mainnet)?.host, "pj.example")
        XCTAssertEqual(AppModel.payjoinRelayURL(custom: "http://127.0.0.1:8080", network: .signet)?.port, 8080)
        XCTAssertNil(AppModel.payjoinRelayURL(custom: "http://pj.example", network: .mainnet))
        XCTAssertNil(AppModel.payjoinRelayURL(custom: "https://user:pw@pj.example", network: .mainnet))
        XCTAssertNil(AppModel.payjoinRelayURL(custom: "not a url", network: .mainnet))
    }

    func testRelaySettingStaysWithItsNetwork() {
        let defaults = makeDefaults()
        defaults.set("https://signet-relay.example", forKey: AppModel.DefaultsKey.payjoinRelay(.signet))
        XCTAssertEqual(AppModel.networkScopedSettings(defaults: defaults, network: .signet).payjoinRelay,
                       "https://signet-relay.example")
        XCTAssertEqual(AppModel.networkScopedSettings(defaults: defaults, network: .mainnet).payjoinRelay, "")
    }

    func testFeeContributionFollowsRateAndStopsAboveDust() {
        let change = Payment(amount: 40_000, scriptPubKey: changeScript)
        XCTAssertEqual(Wallet.payjoinFeeContribution(feeRateSatPerVByte: 2, change: change), 220)
        XCTAssertEqual(Wallet.payjoinFeeContribution(feeRateSatPerVByte: 1.5, change: change), 165)
        XCTAssertEqual(Wallet.payjoinFeeContribution(feeRateSatPerVByte: 2, change: nil), 0)
        XCTAssertEqual(Wallet.payjoinFeeContribution(feeRateSatPerVByte: 2, change: Payment(amount: 400, scriptPubKey: changeScript)), 70,
                       "330 sats of dust stay")
        XCTAssertEqual(Wallet.payjoinFeeContribution(feeRateSatPerVByte: 2, change: Payment(amount: 330, scriptPubKey: changeScript)), 0)
    }
}
