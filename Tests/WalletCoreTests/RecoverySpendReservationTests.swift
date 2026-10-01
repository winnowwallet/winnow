import Foundation
import Testing
import TestSupport
@testable import WalletCore

@Suite("Reserved recovery transaction inputs")
struct RecoverySpendReservationTests {
    let external = Transaction.Output(value: 330, scriptPubKey: Data([0, 32]) + Data(repeating: 7, count: 32))
    private func proposal(_ wallet: Wallet, fee: Int64 = 1000,
                          htlc: Bool = false) async throws -> (Transaction, [WalletUTXO], Transaction.Output) {
        let coins = try await wallet.recoverySpendCoins(requestID: "recovery-a")
        let saved = await wallet.recoverySpendReservations.first
        let next = await wallet.nextChangeIndex
        let index = saved?.changeIndex ?? next
        let destination = try await wallet.scriptPubKey(chain: .change, index: index)
        let source = htlc ? Transaction.Output(value: 20_000, scriptPubKey: external.scriptPubKey) : external
        let outputs = htlc ? [Transaction.Output(value: source.value, scriptPubKey: external.scriptPubKey)] : []
        let change = coins.reduce(Int64(0)) { $0 + $1.amount } + (htlc ? 0 : source.value) - fee
        let first = Transaction.Input(previousOutput: .init(txid: Data(repeating: 8, count: 32), vout: 0),
                                      scriptSig: Data(), sequence: 0xfffffffd,
                                      witness: htlc ? [Data(), Data([0x83]), Data([0x83]), Data([1])] : [])
        let tx = Transaction(version: 2, inputs: [first] + coins.map {
            .init(previousOutput: $0.outpoint, scriptSig: Data(), sequence: 0xfffffffd)
        }, outputs: outputs + [.init(value: change, scriptPubKey: destination)], locktime: 0)
        return (tx, coins, source)
    }
    private func reserve(_ wallet: Wallet, fee: Int64 = 1000,
                         htlc: Bool = false) async throws -> RecoverySpendReservation {
        let (tx, coins, source) = try await proposal(wallet, fee: fee, htlc: htlc)
        return try await wallet.reserveRecoverySpend(requestID: "recovery-a", transaction: tx, coins: coins,
                                                     externalOutput: source, feeLimit: 5000)
    }

    @Test("Wallet signatures reserve coins and a stale prepared spend cannot commit")
    func excludesCompetingSpend() async throws {
        let (wallet, _) = try await fundedWallet()
        let old = try await wallet.buildSend(payments: [.init(amount: 1000, scriptPubKey: external.scriptPubKey)],
                                             feeRateSatPerVByte: 2, chainTip: testChainTip)
        let balance = await wallet.balance
        let saved = try await reserve(wallet)
        let signed = try saved.transaction()
        #expect(signed.inputs[0].witness.isEmpty)
        #expect(signed.inputs.dropFirst().allSatisfy { $0.witness.count == 1 && $0.witness[0].count == 64 })
        #expect(await wallet.spendableUtxos.isEmpty)
        #expect(await wallet.balance == balance)
        await #expect(throws: FundingReservationError.inputsUnavailable) { try await wallet.commit(old) }
        await #expect(throws: (any Error).self) {
            try await wallet.reserveChannelFunding(requestID: "channel", amount: 20_000,
                                                   scriptPubKey: external.scriptPubKey,
                                                   feeRateSatPerVByte: 2, chainTip: testChainTip)
        }
        #expect(try await reserve(wallet) == saved)
    }

    @Test("Restart retains submitted bytes and cannot cancel or reuse their coins")
    func restart() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "wallet.json")
        let keys = InMemoryKeyStore()
        let (wallet, _) = try await fundedWallet(storageURL: url, keyStore: keys)
        let saved = try await reserve(wallet)
        try await wallet.markRecoverySpendSubmitted(requestID: saved.requestID)
        let reopened = try Wallet.open(storageURL: url, keyStore: keys)
        #expect(await reopened.spendableUtxos.isEmpty)
        #expect(await reopened.recoverySpendReservations.first?.submitted == true)
        #expect(await reopened.recoverySpendReservations.first?.rawTransaction == saved.rawTransaction)
        await #expect(throws: FundingReservationError.alreadySubmitted) {
            try await reopened.cancelUnsubmittedRecoverySpend(requestID: saved.requestID)
        }
    }

    @Test("Unsubmitted cancellation releases coins; a fee above the approved cap cannot reserve")
    func cancellationAndBounds() async throws {
        let (wallet, _) = try await fundedWallet()
        let coins = await wallet.spendableUtxos
        let saved = try await reserve(wallet)
        try await wallet.cancelUnsubmittedRecoverySpend(requestID: saved.requestID)
        #expect(await wallet.spendableUtxos == coins)
        await #expect(throws: FundingReservationError.invalidRequest) { try await reserve(wallet, fee: 5001) }
        #expect(await wallet.recoverySpendReservations.isEmpty)
    }

    @Test("HTLC input and paired output survive wallet signing unchanged")
    func htlcAugmentation() async throws {
        let (wallet, _) = try await fundedWallet()
        let (tx, _, _) = try await proposal(wallet, htlc: true)
        let saved = try await reserve(wallet, htlc: true)
        let signed = try saved.transaction()
        #expect(signed.inputs[0] == tx.inputs[0])
        #expect(signed.outputs[0] == tx.outputs[0])
        #expect(saved.fee == 1000)
        #expect(signed.inputs[1].witness.count == 1)
    }

    @Test("Replacement keeps one reservation and removes superseded pending change")
    func replacement() async throws {
        let (wallet, _) = try await fundedWallet()
        let first = try await reserve(wallet)
        try await wallet.markRecoverySpendSubmitted(requestID: first.requestID)
        var firstTx = try first.transaction()
        firstTx.inputs[0].witness = [Data([1])]
        try await wallet.commitRecoverySpendBroadcast(requestID: first.requestID, transaction: firstTx)
        let second = try await reserve(wallet, fee: 2000)
        try await wallet.markRecoverySpendSubmitted(requestID: second.requestID)
        var secondTx = try second.transaction()
        secondTx.inputs[0].witness = [Data([2])]
        try await wallet.commitRecoverySpendBroadcast(requestID: second.requestID, transaction: secondTx)
        #expect(await wallet.recoverySpendReservations.count == 1)
        #expect(await wallet.utxos.contains { $0.txid == firstTx.txid } == false)
        #expect(await wallet.history.first { $0.txid == firstTx.txid }?.replacedBy == secondTx.txid)
        try await wallet.commitRecoverySpendBroadcast(requestID: second.requestID, transaction: secondTx)
        #expect(await wallet.history.filter { $0.txid == secondTx.txid }.count == 1)
    }

    @Test("A changed output or wallet witness cannot be committed")
    func tampering() async throws {
        let (wallet, _) = try await fundedWallet()
        let saved = try await reserve(wallet)
        try await wallet.markRecoverySpendSubmitted(requestID: saved.requestID)
        var tx = try saved.transaction()
        tx.inputs[0].witness = [Data([1])]
        tx.outputs[0].value -= 1
        await #expect(throws: FundingReservationError.requestChanged) {
            try await wallet.commitRecoverySpendBroadcast(requestID: saved.requestID, transaction: tx)
        }
        tx = try saved.transaction()
        tx.inputs[0].witness = [Data([1])]
        tx.inputs[1].witness = [Data(repeating: 0, count: 64)]
        await #expect(throws: FundingReservationError.requestChanged) {
            try await wallet.commitRecoverySpendBroadcast(requestID: saved.requestID, transaction: tx)
        }
    }
}
