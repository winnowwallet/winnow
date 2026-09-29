import Foundation
import Testing
import TestSupport
@testable import WalletCore

@Suite("Channel funding reservations")
struct FundingReservationTests {
    let fundingScript = Data([0, 32]) + Data(repeating: 0x42, count: 32)

    private func reserve(_ wallet: Wallet, id: String = "channel-a") async throws -> FundingReservation {
        try await wallet.reserveChannelFunding(requestID: id, amount: 100_000,
                                               scriptPubKey: fundingScript,
                                               feeRateSatPerVByte: 2, chainTip: testChainTip)
    }

    @Test("Reservation holds real wallet coins without creating spendable change or a pending send")
    func reservesWithoutSending() async throws {
        let (wallet, _) = try await fundedWallet()
        let originalBalance = await wallet.balance
        let historyCount = await wallet.history.count
        let reservation = try await reserve(wallet)
        let transaction = try reservation.transaction()
        #expect(transaction.outputs.contains { $0.value == 100_000 && $0.scriptPubKey == fundingScript })
        #expect(transaction.inputs.allSatisfy { $0.witness.count == 1 && $0.witness[0].count == 64 })
        #expect(await wallet.balance == originalBalance)
        #expect(await wallet.history.count == historyCount)
        #expect(await wallet.spendableUtxos.isEmpty)
        #expect(await wallet.utxos.allSatisfy { $0.height > 0 })
        await #expect(throws: (any Error).self) {
            try await wallet.buildSend(payments: [Payment(amount: 1_000, scriptPubKey: fundingScript)],
                                       feeRateSatPerVByte: 2, chainTip: testChainTip)
        }
        await #expect(throws: WalletError.exportWhilePending) { try await wallet.exportBundle() }
    }

    @Test("Request replay preserves exact signed bytes and change index")
    func idempotent() async throws {
        let (wallet, _) = try await fundedWallet()
        let first = try await reserve(wallet)
        let changeIndex = await wallet.nextChangeIndex
        #expect(try await reserve(wallet) == first)
        #expect(await wallet.nextChangeIndex == changeIndex)
        #expect(await wallet.fundingReservations.count == 1)
        await #expect(throws: FundingReservationError.requestChanged) {
            try await wallet.reserveChannelFunding(requestID: first.requestID, amount: 100_001,
                                                   scriptPubKey: fundingScript,
                                                   feeRateSatPerVByte: 2, chainTip: testChainTip)
        }
    }

    @Test("Restart restores the exact funding bytes and the exclusion from ordinary sends")
    func restart() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("wallet.json")
        let keyStore = InMemoryKeyStore()
        let (wallet, _) = try await fundedWallet(storageURL: url, keyStore: keyStore)
        let reservation = try await reserve(wallet)
        _ = try await wallet.markFundingSubmitted(requestID: reservation.requestID)
        let reopened = try Wallet.open(storageURL: url, keyStore: keyStore)
        #expect(await reopened.spendableUtxos.isEmpty)
        #expect(await reopened.fundingReservations.first?.rawTransaction == reservation.rawTransaction)
        #expect(await reopened.fundingReservations.first?.phase == .submitted)
        await #expect(throws: FundingReservationError.alreadySubmitted) {
            try await reopened.cancelUnsubmittedFunding(requestID: reservation.requestID)
        }
    }

    @Test("Cancel only before submission and never reuse a disclosed change index")
    func cancellation() async throws {
        let (wallet, _) = try await fundedWallet()
        let first = try await reserve(wallet)
        let changeIndex = await wallet.nextChangeIndex
        try await wallet.cancelUnsubmittedFunding(requestID: first.requestID)
        #expect(await wallet.spendableUtxos.count == 1)
        #expect(await wallet.nextChangeIndex == changeIndex)
        let second = try await reserve(wallet, id: "channel-b")
        _ = try await wallet.markFundingSubmitted(requestID: second.requestID)
        await #expect(throws: FundingReservationError.alreadySubmitted) {
            try await wallet.cancelUnsubmittedFunding(requestID: second.requestID)
        }
    }

    @Test("A prepared ordinary send cannot commit coins later reserved by a channel")
    func stalePreparedSend() async throws {
        let (wallet, _) = try await fundedWallet()
        let prepared = try await wallet.buildSend(
            payments: [Payment(amount: 1_000, scriptPubKey: fundingScript)],
            feeRateSatPerVByte: 2, chainTip: testChainTip)
        _ = try await reserve(wallet)
        await #expect(throws: FundingReservationError.inputsUnavailable) { try await wallet.commit(prepared) }
    }

    @Test("Broadcast acknowledgment is exact, idempotent, and prevents ordinary RBF")
    func broadcast() async throws {
        let (wallet, _) = try await fundedWallet()
        let reservation = try await reserve(wallet)
        let tx = try reservation.transaction()
        await #expect(throws: FundingReservationError.alreadySubmitted) {
            try await wallet.commitFundingBroadcast(requestID: reservation.requestID,
                                                     rawTransaction: reservation.rawTransaction)
        }
        _ = try await wallet.markFundingSubmitted(requestID: reservation.requestID)
        await #expect(throws: FundingReservationError.requestChanged) {
            try await wallet.commitFundingBroadcast(requestID: reservation.requestID, rawTransaction: Data())
        }
        try await wallet.commitFundingBroadcast(requestID: reservation.requestID,
                                                 rawTransaction: reservation.rawTransaction)
        let balance = await wallet.balance
        let count = await wallet.history.count
        try await wallet.commitFundingBroadcast(requestID: reservation.requestID,
                                                 rawTransaction: reservation.rawTransaction)
        #expect(await wallet.history.count == count)
        #expect(await wallet.balance == balance)
        #expect(await wallet.fundingReservations.first?.phase == .broadcast)
        #expect(await wallet.feeBumpableTxids.isEmpty)
        await #expect(throws: FundingReservationError.inputsUnavailable) {
            try await wallet.buildFeeBump(txid: tx.txid, feeRateSatPerVByte: 10)
        }
    }

    @Test("Confirmation racing a broadcast acknowledgment is not applied twice")
    func confirmationBeforeAcknowledgment() async throws {
        let (wallet, _) = try await fundedWallet()
        let reservation = try await reserve(wallet)
        _ = try await wallet.markFundingSubmitted(requestID: reservation.requestID)
        let tx = try reservation.transaction()
        try await wallet.apply(match: fakeMatch(height: 201, transactions: [tx]))
        let balance = await wallet.balance
        try await wallet.commitFundingBroadcast(requestID: reservation.requestID,
                                                 rawTransaction: reservation.rawTransaction)
        #expect(await wallet.balance == balance)
        #expect(await wallet.history.filter { $0.txid == tx.txid }.count == 1)
        #expect(await wallet.history.first { $0.txid == tx.txid }?.height == 201)
    }

    @Test("Reorged funding inputs cannot be submitted; reservation survives")
    func reorg() async throws {
        let (wallet, _) = try await fundedWallet()
        let reservation = try await reserve(wallet)
        try await wallet.rollBack(to: 99)
        await #expect(throws: FundingReservationError.inputsUnavailable) {
            try await wallet.markFundingSubmitted(requestID: reservation.requestID)
        }
        #expect(await wallet.fundingReservations.count == 1)
    }

    @Test("A failed durable write leaves inputs available and change index unchanged")
    func failedWrite() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("wallet.json")
        let (wallet, _) = try await fundedWallet(storageURL: url)
        let index = await wallet.nextChangeIndex
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) { try await reserve(wallet) }
        #expect(await wallet.fundingReservations.isEmpty)
        #expect(await wallet.nextChangeIndex == index)
        #expect(await wallet.spendableUtxos.count == 1)
    }

    @Test("Reserved unconfirmed change prevents replacement of its ordinary parent")
    func reservedChangePreventsParentReplacement() async throws {
        let (wallet, _) = try await fundedWallet()
        let parent = try await wallet.buildSend(payments: [Payment(amount: 100_000, scriptPubKey: fundingScript)],
                                                feeRateSatPerVByte: 2, chainTip: testChainTip)
        try await wallet.commit(parent)
        #expect(await wallet.feeBumpableTxids.contains(parent.built.transaction.txid))
        _ = try await reserve(wallet)
        #expect(await wallet.feeBumpableTxids.isEmpty)
        await #expect(throws: FundingReservationError.inputsUnavailable) {
            try await wallet.buildFeeBump(txid: parent.built.transaction.txid, feeRateSatPerVByte: 10)
        }
    }

    @Test("Reload rejects reused change coordinates and altered signing metadata")
    func damagedReservation() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("wallet.json")
        let keyStore = InMemoryKeyStore()
        let (wallet, _) = try await fundedWallet(storageURL: url, keyStore: keyStore)
        _ = try await reserve(wallet)
        let original = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var damaged = original
        damaged["nextChangeIndex"] = 0
        try JSONSerialization.data(withJSONObject: damaged).write(to: url)
        #expect(throws: FundingReservationError.damagedRecord) { try Wallet.open(storageURL: url, keyStore: keyStore) }
        damaged = original
        var reservations = try #require(damaged["fundingReservations"] as? [[String: Any]])
        var coins = try #require(reservations[0]["selected"] as? [[String: Any]])
        coins[0]["index"] = 1
        reservations[0]["selected"] = coins
        damaged["fundingReservations"] = reservations
        try JSONSerialization.data(withJSONObject: damaged).write(to: url)
        #expect(throws: FundingReservationError.damagedRecord) { try Wallet.open(storageURL: url, keyStore: keyStore) }
    }
}
