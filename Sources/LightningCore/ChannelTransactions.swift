import Foundation
import WalletCore

/// BOLT 3 static-remotekey and negotiated anchor commitments. No
/// second transaction model: every constructed transaction is WalletCore's.
public enum ChannelTransactions {
    public struct HTLC: Sendable, Equatable, Codable {
        public let id: UInt64
        public let offered: Bool
        public let amountMsat: UInt64
        public let paymentHash: Data
        public let expiry: UInt32
        public init(id: UInt64, offered: Bool, amountMsat: UInt64, paymentHash: Data, expiry: UInt32) {
            self.id = id; self.offered = offered; self.amountMsat = amountMsat
            self.paymentHash = paymentHash; self.expiry = expiry
        }
    }

    public struct Keys: Sendable {
        public let fundingLocal: Data, fundingRemote: Data
        public let revocation: Data, delayedLocal: Data, paymentRemote: Data
        public let htlcLocal: Data, htlcRemote: Data
        public init(fundingLocal: Data, fundingRemote: Data, revocation: Data,
                    delayedLocal: Data, paymentRemote: Data, htlcLocal: Data, htlcRemote: Data) {
            self.fundingLocal = fundingLocal; self.fundingRemote = fundingRemote
            self.revocation = revocation; self.delayedLocal = delayedLocal; self.paymentRemote = paymentRemote
            self.htlcLocal = htlcLocal; self.htlcRemote = htlcRemote
        }
    }

    public struct Parameters: Sendable {
        public let funding: Transaction.Outpoint
        public let fundingSat: UInt64, localMsat: UInt64, remoteMsat: UInt64
        public let localIsFunder: Bool
        public let dustSat: UInt64, feePerKW: UInt32, delay: UInt16, number: UInt64
        public let openerPaymentBasepoint: Data, accepterPaymentBasepoint: Data
        public let keys: Keys
        public let format: ChannelFormat
        public let htlcs: [HTLC]
        public init(funding: Transaction.Outpoint, fundingSat: UInt64, localMsat: UInt64, remoteMsat: UInt64,
                    localIsFunder: Bool, dustSat: UInt64, feePerKW: UInt32, delay: UInt16, number: UInt64,
                    openerPaymentBasepoint: Data, accepterPaymentBasepoint: Data, keys: Keys, format: ChannelFormat = .staticRemoteKey, htlcs: [HTLC] = []) {
            self.funding = funding; self.fundingSat = fundingSat; self.localMsat = localMsat; self.remoteMsat = remoteMsat
            self.localIsFunder = localIsFunder; self.dustSat = dustSat; self.feePerKW = feePerKW
            self.delay = delay; self.number = number; self.openerPaymentBasepoint = openerPaymentBasepoint
            self.accepterPaymentBasepoint = accepterPaymentBasepoint; self.keys = keys; self.format = format; self.htlcs = htlcs
        }
    }

    public struct HTLCOutput: Sendable {
        public let htlc: HTLC
        public let index: UInt32
        public let witnessScript: Script
    }
    public struct Commitment: Sendable {
        public let parameters: Parameters
        public let transaction: Transaction
        public let fundingScript: Script
        public let delayedScript: Script
        public let htlcOutputs: [HTLCOutput]
        public let actualFeeSat: UInt64
    }
    private struct Output {
        let transaction: Transaction.Output
        let htlc: HTLC?
        let script: Script?
    }

    public static func commitment(_ p: Parameters) throws -> Commitment {
        try validate(p)
        let funding = try ChannelScripts.funding(p.keys.fundingLocal, p.keys.fundingRemote)
        let delayed = try ChannelScripts.delayed(revocation: p.keys.revocation, delayed: p.keys.delayedLocal, delay: p.delay)
        var outputs = try htlcOutputs(p)
        let fee = UInt64(p.feePerKW) * (p.format.commitmentWeight + 172 * UInt64(outputs.count)) / 1000 + p.format.anchorReserveSat
        let local = balance(p.localMsat, fee: p.localIsFunder ? fee : 0)
        let remote = balance(p.remoteMsat, fee: p.localIsFunder ? 0 : fee)
        if local >= p.dustSat {
            outputs.append(Output(transaction: .init(value: Int64(local), scriptPubKey: ChannelScripts.witnessScriptHash(delayed)),
                                  htlc: nil, script: nil))
        }
        if remote >= p.dustSat {
            outputs.append(Output(transaction: .init(value: Int64(remote), scriptPubKey: try ChannelScripts.remoteOutput(paymentKey: p.keys.paymentRemote, format: p.format)),
                                  htlc: nil, script: nil))
        }
        try addAnchors(p, local: local, remote: remote, to: &outputs)
        guard !outputs.isEmpty else { throw LightningError.invalidCommitment }
        outputs.sort(by: precedes)
        let obscured = try obscuredNumber(p)
        let input = Transaction.Input(previousOutput: p.funding, scriptSig: Data(),
                                      sequence: 0x80000000 | UInt32(obscured >> 24))
        let tx = Transaction(version: 2, inputs: [input], outputs: outputs.map(\.transaction),
                             locktime: 0x20000000 | UInt32(obscured & 0xffffff))
        let mapped = outputs.enumerated().compactMap { index, output -> HTLCOutput? in
            guard let htlc = output.htlc, let script = output.script else { return nil }
            return HTLCOutput(htlc: htlc, index: UInt32(index), witnessScript: script)
        }
        return Commitment(parameters: p, transaction: tx, fundingScript: funding, delayedScript: delayed,
                          htlcOutputs: mapped, actualFeeSat: p.fundingSat - UInt64(tx.outputs.reduce(0) { $0 + $1.value }))
    }

    public static func htlcTransaction(commitment: Commitment, output: HTLCOutput) throws -> Transaction {
        guard commitment.htlcOutputs.contains(where: {
            $0.index == output.index && $0.htlc == output.htlc && $0.witnessScript == output.witnessScript
        }),
              commitment.transaction.outputs.indices.contains(Int(output.index)) else { throw LightningError.invalidCommitment }
        let fee = secondStageFee(offered: output.htlc.offered, feePerKW: commitment.parameters.feePerKW, format: commitment.parameters.format)
        let amount = output.htlc.amountMsat / 1000
        guard amount >= fee else { throw LightningError.invalidAmount }
        return Transaction(version: 2, inputs: [.init(previousOutput: .init(txid: commitment.transaction.txid, vout: output.index),
            scriptSig: Data(), sequence: commitment.parameters.format.htlcSequence)], outputs: [.init(value: Int64(amount - fee),
                scriptPubKey: ChannelScripts.witnessScriptHash(commitment.delayedScript))],
            locktime: output.htlc.offered ? output.htlc.expiry : 0)
    }

    public static func fundingDigest(_ c: Commitment) throws -> Data {
        return try SighashBIP143.sighash(tx: c.transaction, inputIndex: 0,
                                       scriptCode: c.fundingScript.bytes, value: Int64(c.parameters.fundingSat))
    }

    /// Accept only verified signatures over this precise commitment before
    /// constructing a broadcastable witness. Signatures exclude the sighash byte.
    public static func signed(_ c: Commitment,
                              localSignature: Data, remoteSignature: Data) throws -> Transaction {
        let keys = c.parameters.keys
        let digest = try fundingDigest(c)
        guard try ChannelScripts.funding(keys.fundingLocal, keys.fundingRemote) == c.fundingScript,
              ChannelKeys.verify(signature: localSignature, digest: digest, publicKey: keys.fundingLocal),
              ChannelKeys.verify(signature: remoteSignature, digest: digest, publicKey: keys.fundingRemote)
        else { throw LightningError.invalidSignature }
        let ordered = keys.fundingLocal.lexicographicallyPrecedes(keys.fundingRemote)
            ? [localSignature, remoteSignature] : [remoteSignature, localSignature]
        var tx = c.transaction
        tx.inputs[0].witness = [Data()] + ordered.map { $0 + Data([1]) } + [c.fundingScript.bytes]
        return tx
    }

    private static func addAnchors(_ p: Parameters, local: UInt64, remote: UInt64, to outputs: inout [Output]) throws {
        guard p.format.hasAnchors else { return }
        let hasHTLCs = outputs.contains { $0.htlc != nil }
        if hasHTLCs || local >= p.dustSat { try addAnchor(p.keys.fundingLocal, to: &outputs) }
        if hasHTLCs || remote >= p.dustSat { try addAnchor(p.keys.fundingRemote, to: &outputs) }
    }
    private static func addAnchor(_ key: Data, to outputs: inout [Output]) throws {
        let script = try ChannelScripts.witnessScriptHash(ChannelScripts.anchor(fundingKey: key))
        outputs.append(Output(transaction: .init(value: 330, scriptPubKey: script), htlc: nil, script: nil))
    }

    private static func balance(_ msat: UInt64, fee: UInt64) -> UInt64 {
        // BOLT 3 trims the funder's output if the proposed fee exhausts it.
        // Negotiating an unaffordable feerate is rejected by the channel policy.
        msat / 1000 > fee ? msat / 1000 - fee : 0
    }
    private static func secondStageFee(offered: Bool, feePerKW: UInt32, format: ChannelFormat) -> UInt64 {
        if format.hasAnchors { return 0 }
        return UInt64(feePerKW) * (offered ? 663 : 703) / 1000
    }
    private static func htlcOutputs(_ p: Parameters) throws -> [Output] {
        try p.htlcs.compactMap { htlc in
            let fee = secondStageFee(offered: htlc.offered, feePerKW: p.feePerKW, format: p.format)
            guard htlc.amountMsat / 1000 >= p.dustSat + fee else { return nil }
            let script = try ChannelScripts.htlc(offered: htlc.offered, revocation: p.keys.revocation,
                local: p.keys.htlcLocal, remote: p.keys.htlcRemote, paymentHash: htlc.paymentHash, expiry: htlc.expiry, format: p.format)
            return Output(transaction: .init(value: Int64(htlc.amountMsat / 1000),
                scriptPubKey: ChannelScripts.witnessScriptHash(script)), htlc: htlc, script: script)
        }
    }
    private static func precedes(_ lhs: Output, _ rhs: Output) -> Bool {
        if lhs.transaction.value != rhs.transaction.value { return lhs.transaction.value < rhs.transaction.value }
        if lhs.transaction.scriptPubKey != rhs.transaction.scriptPubKey {
            return lhs.transaction.scriptPubKey.lexicographicallyPrecedes(rhs.transaction.scriptPubKey)
        }
        if lhs.htlc?.expiry != rhs.htlc?.expiry { return (lhs.htlc?.expiry ?? 0) < (rhs.htlc?.expiry ?? 0) }
        return (lhs.htlc?.id ?? 0) < (rhs.htlc?.id ?? 0)
    }
    private static func obscuredNumber(_ p: Parameters) throws -> UInt64 {
        _ = try ChannelKeys.point(p.openerPaymentBasepoint)
        _ = try ChannelKeys.point(p.accepterPaymentBasepoint)
        let obscurer = ChannelKeys.hash(p.openerPaymentBasepoint + p.accepterPaymentBasepoint)
            .suffix(6).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return p.number ^ obscurer
    }
    private static func validate(_ p: Parameters) throws {
        let maximum: UInt64 = 2_100_000_000_000_000
        guard p.funding.txid.count == 32, p.fundingSat > 0, p.fundingSat <= maximum,
              p.dustSat > 0, p.dustSat <= p.fundingSat, p.number <= ChannelKeys.maximumCommitmentNumber,
              p.htlcs.count <= 966 else { throw LightningError.invalidCommitment }
        var total: UInt64 = 0
        for amount in [p.localMsat, p.remoteMsat] + p.htlcs.map(\.amountMsat) {
            let sum = total.addingReportingOverflow(amount)
            guard !sum.overflow, sum.partialValue <= p.fundingSat * 1000 else { throw LightningError.invalidAmount }
            total = sum.partialValue
        }
        guard total == p.fundingSat * 1000 else { throw LightningError.invalidAmount }
        try validateHTLCs(p.htlcs)
    }
    private static func validateHTLCs(_ htlcs: [HTLC]) throws {
        for htlc in htlcs {
            guard htlc.amountMsat > 0, htlc.paymentHash.count == 32 else { throw LightningError.invalidHash }
        }
        // IDs are scoped to the offerer, so the two directions may share an ID.
        for offered in [true, false] {
            let ids = htlcs.filter { $0.offered == offered }.map(\.id)
            guard Set(ids).count == ids.count else { throw LightningError.invalidCommitment }
        }
    }
}
