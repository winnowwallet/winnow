import Foundation
import P256K
import WalletCore

extension LightningEngine {
    /// Pure preview. The caller supplies Winnow's already-filtered spendable coins
    /// and an explicitly approved total fee ceiling; no coins or channel mutate.
    public func anchorFeeBumpQuote(id: Data, channelID: Data, peer: Data, coins: [WalletUTXO], destination: Data,
                                  feeRateSatPerVByte: Double, totalFeeLimitSat: UInt64,
                                  htlcTransactionID: Data? = nil, replacingTxid: Data? = nil) throws -> AnchorFeeBump {
        try healthy()
        guard chainIsCurrent, state.recoveryRestore == nil else { throw LightningError.invalidState }
        let channel = state.channels[try channelIndex(channelID, peer: peer)]
        try requireAnchorChannel(channel)
        try requireFeeBumpCapacity(channel)
        let target = try feeBumpTarget(channel, htlcTransactionID: htlcTransactionID)
        let replacing = try replacement(channel, txid: replacingTxid)
        let excluded = try reservedAnchorOutpoints().subtracting(replacing?.selected.map(\.outpoint) ?? [])
        return try AnchorFeeBumpBuilder.quote(id: id, channelID: channel.id, target: target,
            coins: coins.filter { !excluded.contains($0.outpoint) }, destination: destination,
            rate: feeRateSatPerVByte, limit: totalFeeLimitSat, replacing: replacing)
    }
    /// Wallet inputs are reserved and signed first. The anchor signature and
    /// exact broadcast intentions are durable before either transaction leaves.
    public func commitAnchorFeeBump(_ quote: AnchorFeeBump, peer: Data, walletSignedTransaction: Transaction) throws -> [Event] {
        try healthy()
        guard chainIsCurrent, state.recoveryRestore == nil else { throw LightningError.invalidState }
        let index = try channelIndex(quote.channelID, peer: peer)
        let channel = state.channels[index]
        try requireAnchorChannel(channel)
        if let saved = channel.feeBumps?.first(where: { $0.id == quote.id }) {
            guard saved.unsignedTransaction == quote.unsignedTransaction else { throw LightningError.invalidState }
            return try feeBumpEvents(saved)
        }
        try requireFeeBumpCapacity(channel)
        var committed = try authorizeFeeBump(quote, channel: channel, signed: walletSignedTransaction)
        committed.signedTransaction = try signAnchorBump(committed, channel: channel, signed: walletSignedTransaction)
        var next = state
        if committed.kind == .commitment {
            next.channels[index].phase = .closing
            next.channels[index].closingTransaction = committed.parentTransaction
            next.outbox.removeAll { $0.channelID == quote.channelID && $0.peer == peer }
            _ = markPaymentsRecovering(channelID: quote.channelID, in: &next)
        }
        next.channels[index].feeBumps = (channel.feeBumps ?? []) + [committed]
        try persist(next)
        return try feeBumpEvents(committed)
    }
    public func anchorFeeBumps(channelID: Data, peer: Data) throws -> [AnchorFeeBump] {
        try healthy()
        return state.channels[try channelIndex(channelID, peer: peer)].feeBumps ?? []
    }
    /// Reserved until a known replacement confirms. The wallet also persists
    /// its own reservation, closing the cross-journal crash window.
    public func reservedAnchorOutpoints() throws -> Set<Transaction.Outpoint> {
        try healthy()
        return Set(state.channels.flatMap { channel in
            (channel.feeBumps ?? []).flatMap(\.selected).map(\.outpoint)
        })
    }
    public func feeBumpableHTLCs(channelID: Data, peer: Data) throws -> [Data] {
        try healthy()
        let channel = state.channels[try channelIndex(channelID, peer: peer)]
        try requireAnchorChannel(channel)
        return try channel.resolutions.compactMap { spend in
            let tx = try Transaction.decode(spend.transaction)
            return isAnchorHTLC(tx) ? tx.txid : nil
        }
    }
    private func requireAnchorChannel(_ channel: ChannelState) throws {
        guard channel.local.format.hasAnchors, !channel.dataLossDetected, channel.recovery != nil,
              channel.signedCommitment != nil else { throw LightningError.invalidState }
    }
    private func requireFeeBumpCapacity(_ channel: ChannelState) throws {
        guard (channel.feeBumps?.count ?? 0) < 64 else { throw LightningError.invalidState }
    }
    private func feeBumpTarget(_ channel: ChannelState, htlcTransactionID: Data?) throws -> AnchorFeeBumpBuilder.Target {
        if let htlcTransactionID { return try htlcFeeBumpTarget(channel, txid: htlcTransactionID) }
        let parent = try Transaction.decode(channel.signedCommitment!)
        if let raw = channel.observedFundingSpend {
            guard try Transaction.decode(raw).txid == parent.txid else { throw LightningError.invalidState }
        }
        guard channel.closingTransaction == nil || channel.closingTransaction == channel.signedCommitment else { throw LightningError.invalidState }
        let script = try ChannelScripts.anchor(fundingKey: channel.local.funding)
        guard let index = parent.outputs.firstIndex(where: { $0.value == 330 && $0.scriptPubKey == ChannelScripts.witnessScriptHash(script) })
        else { throw LightningError.invalidCommitment }
        let tx = Transaction(version: 2, inputs: [.init(previousOutput: .init(txid: parent.txid, vout: UInt32(index)),
            scriptSig: Data(), sequence: 0xfffffffd)], outputs: [], locktime: 0)
        let fee = channel.capacity - UInt64(parent.outputs.reduce(0) { $0 + $1.value })
        return .init(parent: parent, transaction: tx, parentFee: fee, kind: .commitment, anchorScript: script)
    }
    private func htlcFeeBumpTarget(_ channel: ChannelState, txid: Data) throws -> AnchorFeeBumpBuilder.Target {
        guard let spend = try channel.resolutions.first(where: { try Transaction.decode($0.transaction).txid == txid }),
              let raw = channel.observedFundingSpend else { throw LightningError.invalidState }
        let tx = try Transaction.decode(spend.transaction), parent = try Transaction.decode(raw)
        guard isAnchorHTLC(tx), tx.inputs[0].previousOutput.txid == parent.txid,
              state.scan.transactions.contains(where: { (try? Transaction.decode($0.raw).txid) == parent.txid })
        else { throw LightningError.invalidState }
        return .init(parent: parent, transaction: tx, parentFee: 0, kind: .htlc, anchorScript: nil)
    }
    private func replacement(_ channel: ChannelState, txid: Data?) throws -> AnchorFeeBump? {
        guard let txid else { return nil }
        guard let bump = try channel.feeBumps?.first(where: { try $0.transaction().txid == txid }),
              !(channel.feeBumps ?? []).contains(where: { $0.replacesTxid == txid }) else { throw LightningError.invalidState }
        return bump
    }
    private func authorizeFeeBump(_ quote: AnchorFeeBump, channel: ChannelState, signed: Transaction) throws -> AnchorFeeBump {
        try AnchorFeeBumpBuilder.validate(quote)
        let original = try Transaction.decode(quote.unsignedTransaction)
        guard signed.serialized(includeWitness: false) == original.serialized(includeWitness: false),
              signed.inputs[0].witness == original.inputs[0].witness else { throw LightningError.invalidCommitment }
        let targetID = quote.kind == .htlc ? original.inputs[0].previousOutput : nil
        let target = try feeBumpTarget(channel, htlcTransactionID: try targetID.map { _ in
            guard let tx = try channel.resolutions.first(where: { try Transaction.decode($0.transaction).inputs[0].previousOutput == targetID! })
            else { throw LightningError.invalidState }
            return try Transaction.decode(tx.transaction).txid
        })
        guard quote.parentTransaction == target.parent.serialized(includeWitness: true),
              original.inputs[0].previousOutput == target.transaction.inputs[0].previousOutput,
              quote.parentFeeSat == target.parentFee else { throw LightningError.invalidCommitment }
        try validateTargetOutputs(original, target: target)
        try validateReplacement(quote, channel: channel, target: target)
        try verifyWalletSignatures(signed, quote: quote)
        return quote
    }
    private func validateTargetOutputs(_ tx: Transaction, target: AnchorFeeBumpBuilder.Target) throws {
        guard tx.version == target.transaction.version, tx.locktime == target.transaction.locktime,
              tx.inputs[0] == target.transaction.inputs[0],
              tx.outputs.count == target.transaction.outputs.count + 1,
              Array(tx.outputs.dropLast()) == target.transaction.outputs,
              ChannelTerms.validShutdown(tx.outputs.last!.scriptPubKey, anySegwit: true) else { throw LightningError.invalidCommitment }
    }
    private func validateReplacement(_ quote: AnchorFeeBump, channel: ChannelState, target: AnchorFeeBumpBuilder.Target) throws {
        let replacing = try replacement(channel, txid: quote.replacesTxid)
        try AnchorFeeBumpBuilder.validateReplacementTarget(target, replacing: replacing)
        if let replacing {
            guard replacing.kind == quote.kind, replacing.parentTransaction == quote.parentTransaction,
                  replacing.selected == quote.selected, quote.feeSat >= replacing.feeSat + UInt64(AnchorFeeBumpBuilder.vsize(try quote.transaction())),
                  quote.packageFeeSat <= replacing.totalFeeLimitSat else { throw LightningError.invalidAmount }
        }
        let excluded = try reservedAnchorOutpoints().subtracting(replacing?.selected.map(\.outpoint) ?? [])
        guard !quote.selected.contains(where: { excluded.contains($0.outpoint) }) else { throw LightningError.invalidState }
    }
    private func verifyWalletSignatures(_ tx: Transaction, quote: AnchorFeeBump) throws {
        let spent = try quote.spentOutputs()
        for index in tx.inputs.indices.dropFirst() {
            let witness = tx.inputs[index].witness, output = spent[index]
            guard output.scriptPubKey.count == 34, output.scriptPubKey.prefix(2) == Data([0x51, 32]),
                  witness.count == 1, witness[0].count == 64 else { throw LightningError.invalidSignature }
            let digest = try SighashBIP341.sighash(tx: tx, inputIndex: index, spentOutputs: spent)
            var message = [UInt8](digest)
            let signature = try P256K.Schnorr.SchnorrSignature(dataRepresentation: witness[0])
            guard P256K.Schnorr.XonlyKey(dataRepresentation: output.scriptPubKey.suffix(32)).isValid(signature, for: &message)
            else { throw LightningError.invalidSignature }
        }
    }
    private func signAnchorBump(_ quote: AnchorFeeBump, channel: ChannelState, signed: Transaction) throws -> Data {
        var tx = signed
        if quote.kind == .commitment {
            let script = try ChannelScripts.anchor(fundingKey: channel.local.funding)
            let digest = try SighashBIP143.sighash(tx: tx, inputIndex: 0, scriptCode: script.bytes, value: 330)
            tx.inputs[0].witness = [try ChannelKeys.sign(digest: digest, secret: channel.secrets.funding) + Data([1]), script.bytes]
        }
        return tx.serialized(includeWitness: true)
    }
    func feeBumpEvents(_ bump: AnchorFeeBump) throws -> [Event] {
        guard let raw = bump.signedTransaction else { throw LightningError.invalidState }
        if bump.kind == .commitment {
            return [.broadcastClose(channelID: bump.channelID, transaction: bump.parentTransaction),
                    .broadcastRecovery(channelID: bump.channelID, transaction: raw)]
        }
        let confirmed = try state.scan.transactions.map { try ChannelResolution.Confirmed(height: $0.height, tx: Transaction.decode($0.raw)) }
        let tx = try Transaction.decode(raw)
        let spend = ChannelResolution.Spend(tx, delay: 1, height: tx.locktime)
        guard try ChannelResolution.available(spend, confirmed: confirmed, height: chainHeight) else { return [] }
        return [.broadcastRecovery(channelID: bump.channelID, transaction: raw)]
    }
    func pendingFeeBumpEvents(channel: ChannelState, confirmed: [ChannelResolution.Confirmed]) throws -> [Event] {
        let records = channel.feeBumps ?? []
        let replaced = Set(records.compactMap(\.replacesTxid))
        return try records.flatMap { record in
            let txid = try record.transaction().txid
            guard !replaced.contains(txid), !confirmed.contains(where: { $0.tx.txid == txid }) else { return [Event]() }
            guard let raw = record.signedTransaction else { throw LightningError.storageFailed }
            if record.kind == .htlc {
                let tx = try Transaction.decode(raw)
                let spend = ChannelResolution.Spend(tx, delay: 1, height: tx.locktime)
                guard try ChannelResolution.available(spend, confirmed: confirmed, height: chainHeight) else { return [] }
            }
            return [.broadcastRecovery(channelID: record.channelID, transaction: raw)]
        }
    }
    func isAnchorHTLC(_ tx: Transaction) -> Bool {
        guard tx.inputs.count == 1, tx.outputs.count == 1 else { return false }
        let witness = tx.inputs[0].witness
        guard witness.count == 5 else { return false }
        return witness[1].last == 0x83 && witness[2].last == 0x83
    }
    static func validateAnchorFeeBumps(_ state: State) throws {
        for channel in state.channels {
            let records = channel.feeBumps ?? []
            guard records.count <= 64, Set(records.map(\.id)).count == records.count else { throw LightningError.storageFailed }
            for record in records {
                guard channel.local.format.hasAnchors, record.channelID == channel.id else { throw LightningError.storageFailed }
                try AnchorFeeBumpBuilder.validate(record)
            }
        }
    }
}
