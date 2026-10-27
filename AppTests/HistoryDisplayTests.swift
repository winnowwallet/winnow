@testable import WinnowApp
import WalletCore
import XCTest

@MainActor
final class HistoryDisplayTests: XCTestCase {
    private func entry(_ id: UInt8, height: UInt32 = 0, replacedBy: UInt8? = nil) -> HistoryEntry {
        HistoryEntry(txid: Data(repeating: id, count: 32), height: height,
                     received: 0, spent: 1,
                     replacedBy: replacedBy.map { Data(repeating: $0, count: 32) })
    }

    func testReplacementStaysBesideItsOriginalBeforeAndAfterConfirmation() {
        let receipts = (1 ... 100).map { entry(UInt8($0), height: UInt32($0)) }
        let original = entry(101, replacedBy: 103)
        let otherPending = entry(102)
        let replacement = entry(103)
        let history = receipts + [original, otherPending, replacement]

        XCTAssertEqual(Array(AppModel.historyForDisplay(history).prefix(3)).map(\.txid),
                       [replacement.txid, original.txid, otherPending.txid],
                       "the replaced payment must not be buried below old receipts")

        var confirmed = history
        confirmed[confirmed.count - 1].height = 110
        confirmed.append(entry(104, height: 111))
        XCTAssertEqual(Array(AppModel.historyForDisplay(confirmed).prefix(5)).map(\.txid),
                       [otherPending.txid, entry(104).txid, replacement.txid, original.txid, entry(100).txid],
                       "the whole replacement group must move below newer confirmed payments")
    }

    func testRepeatedBumpsFollowTheirFinalPaymentRegardlessOfImportOrder() {
        let original = entry(1, replacedBy: 2)
        let middle = entry(2, replacedBy: 3)
        let final = entry(3, height: 110)
        let recent = entry(4, height: 111)
        XCTAssertEqual(AppModel.historyForDisplay([middle, recent, original, final]).map(\.txid),
                       [recent.txid, final.txid, middle.txid, original.txid])
    }

    func testIncompleteOrCyclicReplacementLinksDoNotHideHistory() {
        let history = [entry(1, replacedBy: 2), entry(2, replacedBy: 1),
                       entry(3, replacedBy: 9), entry(4, height: 100)]
        let displayed = AppModel.historyForDisplay(history)
        XCTAssertEqual(Set(displayed.map(\.txid)), Set(history.map(\.txid)))
        XCTAssertEqual(displayed.first?.txid, entry(4).txid)
    }
    private func row(_ id: UInt8, height: UInt32, received: Int64, spent: Int64) -> HistoryEntry {
        HistoryEntry(txid: Data(repeating: id, count: 32), height: height, received: received, spent: spent)
    }

    private func account(_ id: String, name: String, history: [HistoryEntry]) -> MultisigAccountRecord {
        MultisigAccountRecord(id: id, name: name, descriptor: "tr(\(id))", createdAtHeight: 0, history: history)
    }

    /// The one list: wallet rows, account rows named, a transaction in both
    /// histories folded into one transfer row, drafts on top, newest first.
    func testPaymentsMergeWalletAndAccountRowsAndFoldTransfers() {
        let walletReceive = row(1, height: 100, received: 10_000, spent: 0)
        let toAccount = row(2, height: 105, received: 4_000, spent: 10_000)       // the wallet paid the account
        let accountSide = row(2, height: 105, received: 5_000, spent: 0)
        let fromAccount = row(3, height: 110, received: 0, spent: 5_000)          // the account paid the wallet
        let walletSide = row(3, height: 110, received: 4_500, spent: 0)
        let bothSpent = row(4, height: 111, received: 0, spent: 1_000)            // not a transfer: both sides spent
        let bothSpentAccount = row(4, height: 111, received: 0, spent: 2_000)
        let accountPending = row(5, height: 0, received: 0, spent: 3_000)
        let household = account("acct", name: "Household", history: [accountSide, fromAccount, bothSpentAccount, accountPending])
        let draft = DisplayedPayment(entry: row(9, height: 0, received: 0, spent: 500),
                                     source: .draft(name: "Household", signatures: "1 of 2"), accountID: "acct")

        let rows = AppModel.payments(wallet: [walletReceive, toAccount, walletSide, bothSpent],
                                     accounts: [household], drafts: [draft])
        XCTAssertEqual(rows.map(\.txid), [draft.txid, accountPending.txid, bothSpent.txid, bothSpentAccount.txid,
                                          fromAccount.txid, toAccount.txid, walletReceive.txid])
        XCTAssertEqual(rows[0].source, .draft(name: "Household", signatures: "1 of 2"))
        XCTAssertEqual(rows[1].source, .account(name: "Household"))
        XCTAssertEqual(rows[2].source, .wallet)
        XCTAssertEqual(rows[3].source, .account(name: "Household"))
        XCTAssertEqual(rows[4].source, .transfer(from: "Household", to: "Wallet", amount: 4_500))
        XCTAssertEqual(rows[4].accountID, "acct", "the transfer row carries the spender's entry")
        XCTAssertEqual(rows[5].source, .transfer(from: "Wallet", to: "Household", amount: 5_000))
        XCTAssertNil(rows[5].accountID)
        XCTAssertEqual(rows[5].entry.spent, 10_000)
        XCTAssertEqual(rows[6].source, .wallet)
        XCTAssertEqual(rows.map(\.accountName), [ "Household", "Household", nil, "Household", "Household", "Household", nil])
    }

    func testRecipientActionsUseActualExternalOutputs() throws {
        let addresses = [
            "1BoatSLRHtKNngkdXEeobR76b53LETtpyT",
            "3J98t1WpEZ73CNmQviecrnyiWrnqRhWNLy",
        ]
        let scripts = try addresses.map { try AddressDecoder.scriptPubKey(for: $0, network: .mainnet) }
        let alice = PersonRecord(id: "alice", name: "Alice", payTo: .address(addresses[0]))
        let transaction = Transaction(version: 2, inputs: [Transaction.Input(
            previousOutput: Transaction.Outpoint(txid: Data(repeating: 1, count: 32), vout: 0), scriptSig: Data(), sequence: 0xffff_fffd)],
            outputs: scripts.map { Transaction.Output(value: 1_000, scriptPubKey: $0) }, locktime: 0)
        var receipt = HistoryEntry(txid: transaction.txid, height: 10, received: 1_000, spent: 2_100,
                                   rawTransaction: transaction.serialized(includeWitness: false))
        let recipients = AppModel.paymentRecipients(receipt, owned: [scripts[1]],
                                                    people: [scripts[0]: alice], network: .mainnet)
        XCTAssertEqual(recipients.map(\.address), [addresses[0]])
        XCTAssertEqual(recipients.first?.person?.name, "Alice")
        XCTAssertEqual(AppModel.paymentRecipients(receipt, owned: [], people: [:], network: .mainnet).count, 2)
        receipt.spent = 0
        XCTAssertTrue(AppModel.paymentRecipients(receipt, owned: [], people: [:], network: .mainnet).isEmpty,
                      "incoming outputs do not identify a sender")
    }

}
