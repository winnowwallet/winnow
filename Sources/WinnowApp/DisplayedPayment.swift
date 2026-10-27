import Foundation
import WalletCore

/// One row of the Transactions list: a wallet payment, an account's, a move
/// between the wallet and one of this phone's accounts (one row, never two),
/// or an account's draft awaiting signatures. Built by `AppModel.payments`
/// from the wallet's history and every account's, newest first with drafts
/// on top. Exercised by AppTests/HistoryDisplayTests and
/// AppTests/MultisigAccountFlowTests, and on screen by the journeys.
struct DisplayedPayment: Equatable, Identifiable {
    enum Source: Equatable {
        case wallet
        case account(name: String)
        /// The same transaction in two histories: `from` paid `to`
        /// (`"Wallet"` or an account's name), `amount` sats.
        case transfer(from: String, to: String, amount: Int64)
        /// An account's draft: `signatures` reads "1 of 2".
        case draft(name: String, signatures: String)
    }

    var entry: HistoryEntry
    var source: Source
    /// The account whose history `entry` comes from; nil for the wallet's.
    var accountID: String?

    var txid: Data { entry.txid }
    var id: String { "\(accountID ?? "wallet")-\(entry.txid.displayHex)" }

    var isDraft: Bool {
        if case .draft = source { return true }
        return false
    }

    /// The account named on the row, if any.
    var accountName: String? {
        switch source {
        case .wallet: nil
        case let .account(name), let .draft(name, _): name
        case let .transfer(from, to, _): from == DisplayedPayment.walletName ? to : from
        }
    }

    static let walletName = "Wallet"
}

extension AppModel {
    /// The merged list: every wallet entry and every account entry, with a
    /// transaction in both histories folded into one transfer row when one
    /// side spent and the other only received, drafts first, then the
    /// wallet's own ordering (`historyForDisplay`) over the rest.
    static func payments(wallet: [HistoryEntry], accounts: [MultisigAccountRecord],
                         drafts: [DisplayedPayment]) -> [DisplayedPayment] {
        var rows = wallet.map { DisplayedPayment(entry: $0, source: .wallet, accountID: nil) }
        for account in accounts {
            rows += account.history.map { DisplayedPayment(entry: $0, source: .account(name: account.name), accountID: account.id) }
        }
        rows = foldTransfers(rows, names: Dictionary(accounts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }))
        let order = historyForDisplay(rows.map(\.entry))
        var rank: [Data: Int] = [:]
        for (position, entry) in order.enumerated() where rank[entry.txid] == nil { rank[entry.txid] = position }
        let sorted = rows.sorted {
            let left = rank[$0.txid] ?? Int.max
            let right = rank[$1.txid] ?? Int.max
            return left != right ? left < right : ($0.accountID ?? "") < ($1.accountID ?? "")
        }
        return drafts + sorted
    }

    /// Rows sharing a txid where exactly one spent and the others only
    /// received become one transfer row carrying the spender's entry.
    private static func foldTransfers(_ rows: [DisplayedPayment], names: [String: String]) -> [DisplayedPayment] {
        var groups: [Data: [Int]] = [:]
        for (position, row) in rows.enumerated() { groups[row.txid, default: []].append(position) }
        var folded: Set<Int> = []
        var result = rows
        for positions in groups.values where positions.count > 1 {
            let spenders = positions.filter { rows[$0].entry.spent > 0 }
            let receivers = positions.filter { rows[$0].entry.spent == 0 && rows[$0].entry.received > 0 }
            guard spenders.count == 1, receivers.count == positions.count - 1, let receiver = receivers.first else { continue }
            let spender = spenders[0]
            let from = rows[spender].accountID.flatMap { names[$0] } ?? DisplayedPayment.walletName
            let to = rows[receiver].accountID.flatMap { names[$0] } ?? DisplayedPayment.walletName
            let amount = receivers.reduce(0) { $0 + rows[$1].entry.received }
            result[spender].source = .transfer(from: from, to: to, amount: amount)
            folded.formUnion(receivers)
        }
        return result.enumerated().filter { !folded.contains($0.offset) }.map(\.element)
    }

    /// The row for an account's draft: the unsigned transaction as a pending
    /// spend of the account, with the signatures collected so far on its
    /// best leaf. Nil when the draft no longer reviews against the account.
    func draftRow(for record: MultisigAccountRecord) -> DisplayedPayment? {
        guard let draft = record.draft, let psbt = try? draft.psbt(),
              let screen = try? multisigSigningScreen(psbt, record: record),
              let unsigned = try? psbt.unsignedTransaction(),
              let account = try? multisigAccount(for: record) else { return nil }
        var outputs = HistoryEntry.Outputs()
        for (vout, output) in unsigned.outputs.enumerated() where output.value > 0 {
            if screen.review.outputs.indices.contains(vout), screen.review.outputs[vout].isAccountOwned {
                outputs.change.append(UInt32(vout))
            } else {
                outputs.external.append(.init(vout: UInt32(vout), amount: output.value, scriptPubKey: output.scriptPubKey))
            }
        }
        let change = outputs.change.reduce(0) { $0 + unsigned.outputs[Int($1)].value }
        let signatures = screen.paths.map { path in
            "\(screen.approvals[path, default: []].count) of \(account.threshold(on: path))"
        }.max { lhs, rhs in lhs.count < rhs.count } ?? "0 of \(account.threshold)"
        let entry = HistoryEntry(txid: unsigned.txid, height: 0, received: change, spent: screen.review.inputTotal,
                                 fee: screen.review.fee, rawTransaction: unsigned.serialized(includeWitness: false),
                                 outputs: outputs)
        return DisplayedPayment(entry: entry, source: .draft(name: record.name, signatures: signatures), accountID: record.id)
    }

    /// The row a payment screen shows for a transaction id: the merged
    /// list's, else the wallet's own entry.
    func displayedPayment(txid: Data) -> DisplayedPayment? {
        if let row = status.payments.first(where: { $0.txid == txid }) { return row }
        return status.history.first { $0.txid == txid }.map { DisplayedPayment(entry: $0, source: .wallet, accountID: nil) }
    }
}
