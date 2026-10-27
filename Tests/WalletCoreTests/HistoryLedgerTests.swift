import Foundation
import Testing
@testable import WalletCore

/// The history rules the wallet and a multisig account share
/// (`HistoryLedger`): the exact fee, confirming in place, classifying
/// outputs, and what a reorg re-pends or drops.
@Suite("History ledger")
struct HistoryLedgerTests {
    private func transaction(spending outpoints: [Transaction.Outpoint] = [], paying values: [Int64]) -> Transaction {
        Transaction(version: 2,
                    inputs: outpoints.map { Transaction.Input(previousOutput: $0, scriptSig: Data(), sequence: 0xffff_fffd) },
                    outputs: values.enumerated().map { position, value in
                        Transaction.Output(value: value,
                                           scriptPubKey: Data([0x51, 0x20]) + Data(repeating: UInt8(position + 1), count: 32))
                    },
                    locktime: 0)
    }

    @Test("the fee is exact only when every input was ours and the inputs exceed the outputs")
    func exactFee() {
        let tx = transaction(paying: [40_000, 9_000])
        #expect(HistoryLedger.exactFee(spent: 50_000, of: tx, allInputsOurs: true) == 1_000)
        #expect(HistoryLedger.exactFee(spent: 50_000, of: tx, allInputsOurs: false) == nil)
        #expect(HistoryLedger.exactFee(spent: 0, of: tx, allInputsOurs: true) == nil)
        #expect(HistoryLedger.exactFee(spent: 49_000, of: tx, allInputsOurs: true) == nil)
    }

    @Test("an unknown transaction is appended, a pending one confirms in place and keeps an agreeing breakdown")
    func record() {
        let tx = transaction(spending: [.init(txid: Data(repeating: 1, count: 32), vout: 0)], paying: [40_000, 9_000])
        let block = Data(repeating: 0xbb, count: 32)
        var history: [HistoryEntry] = []
        #expect(HistoryLedger.record(&history, tx: tx, txid: tx.txid, height: 500, blockHash: block,
                                     received: 40_000, spent: 0, fee: nil) == false)
        #expect(history.count == 1)
        #expect(history[0].height == 500 && history[0].blockHash == block && history[0].outputs == nil)
        #expect(history[0].rawTransaction == tx.serialized(includeWitness: false))
        #expect(history[0].fundingScripts == FundingSources.fundingScripts(of: tx))

        let agreeing = HistoryEntry.Outputs(
            external: [.init(vout: 0, amount: 40_000, scriptPubKey: tx.outputs[0].scriptPubKey)], change: [1])
        var pending = [HistoryEntry(txid: tx.txid, height: 0, received: 9_000, spent: 50_000, fee: 1_000, outputs: agreeing)]
        #expect(HistoryLedger.record(&pending, tx: tx, txid: tx.txid, height: 501, blockHash: block,
                                     received: 0, spent: 50_000, fee: 1_000) == true)
        #expect(pending.count == 1)
        #expect(pending[0].height == 501 && pending[0].blockHash == block && pending[0].outputs == agreeing)
        #expect(pending[0].received == 9_000 && pending[0].spent == 50_000 && pending[0].fee == 1_000)

        // Display metadata the bytes contradict is dropped, not kept.
        let contradicting = HistoryEntry.Outputs(
            external: [.init(vout: 0, amount: 1, scriptPubKey: tx.outputs[0].scriptPubKey)])
        var imported = [HistoryEntry(txid: tx.txid, height: 0, received: 0, spent: 50_000, outputs: contradicting)]
        HistoryLedger.record(&imported, tx: tx, txid: tx.txid, height: 501, blockHash: block,
                             received: 0, spent: 50_000, fee: nil)
        #expect(imported[0].outputs == nil)
    }

    @Test("outputs are change, external or the owner's receive, and zero-value ones are nobody's")
    func classifyOutputs() {
        let tx = transaction(paying: [40_000, 9_000, 0, 5_000])
        let outputs = HistoryLedger.classifyOutputs(of: tx) { script in
            switch script {
            case tx.outputs[1].scriptPubKey: .change
            case tx.outputs[3].scriptPubKey: .receive
            default: nil
            }
        }
        #expect(outputs.change == [1])
        #expect(outputs.external == [.init(vout: 0, amount: 40_000, scriptPubKey: tx.outputs[0].scriptPubKey)])
    }

    @Test("a reorg re-pends spenders and drops receives above the fork, and a repeat changes nothing")
    func rewind() {
        let kept = HistoryEntry(txid: Data(repeating: 1, count: 32), height: 600, received: 1_000, spent: 0,
                                blockHash: Data(repeating: 6, count: 32))
        let spender = HistoryEntry(txid: Data(repeating: 2, count: 32), height: 601, received: 0, spent: 1_000,
                                   blockHash: Data(repeating: 7, count: 32))
        let receive = HistoryEntry(txid: Data(repeating: 3, count: 32), height: 602, received: 2_000, spent: 0)
        var history = [kept, spender, receive]
        #expect(HistoryLedger.rewind(&history, above: 600) == [spender.txid])
        #expect(history.map(\.txid) == [kept.txid, spender.txid])
        #expect(history[0] == kept)
        #expect(history[1].height == 0 && history[1].blockHash == nil && history[1].spent == 1_000)
        let once = history
        #expect(HistoryLedger.rewind(&history, above: 600).isEmpty)
        #expect(history == once)
    }
}
