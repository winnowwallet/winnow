import Foundation
import WalletCore

enum ChannelResolution {
    struct Policy: Codable, Equatable {
        let destination: Data
        let feeSat: UInt64
        var script: Script { Script(destination) }
        var dust: UInt64 { UInt64(CoinSelection.dustThreshold(scriptPubKey: destination)) }
        func economic(_ value: Int64) -> Bool { value > 0 && UInt64(value) >= feeSat + dust }
    }
    struct Spend: Codable {
        let transaction: Data
        let relativeDelay: UInt16
        let minimumHeight: UInt32
        let unconfirmedParent: Data?
        init(_ tx: Transaction, delay: UInt16 = 0, height: UInt32 = 0, unconfirmedParent: Data? = nil) {
            transaction = tx.serialized(includeWitness: true); relativeDelay = delay; minimumHeight = height
            self.unconfirmedParent = unconfirmedParent
        }
    }
    struct Confirmed {
        let height: UInt32
        let tx: Transaction
    }
    struct Context {
        let channel: ChannelState
        let policy: Policy
        let confirmed: [Confirmed]
        let preimages: [Data]

        func candidates(parent: Transaction) throws -> [Spend] {
            var result = try immediate(parent)
            guard let commitment = try recognized(parent) else { return result }
            if commitment.local {
                result += try local(commitment.value, parent: parent)
            } else if commitment.value.parameters.number < channel.revocations.received {
                result += try penalty(commitment.value, parent: parent)
            } else {
                result += try remote(commitment.value)
            }
            return result
        }
        func recognized(_ parent: Transaction) throws -> (local: Bool, value: ChannelTransactions.Commitment)? {
            if let raw = channel.signedCommitment, try Transaction.decode(raw).txid == parent.txid {
                return (true, try channel.commitment(localOwner: true))
            }
            guard let number = try channel.remoteCommitmentNumber(parent),
                  number <= channel.remoteNumber + (channel.awaitingRevocation ? 1 : 0) else { return nil }
            let commitment = try channel.commitment(localOwner: false, number: number)
            guard commitment.transaction.txid == parent.txid else { return nil }
            return (false, commitment)
        }
        private func immediate(_ parent: Transaction) throws -> [Spend] {
            let script = try ChannelScripts.remoteOutput(paymentKey: channel.local.payment, format: channel.local.format)
            return try parent.outputs.enumerated().compactMap { index, output in
                guard output.scriptPubKey == script, policy.economic(output.value) else { return nil }
                return Spend(try ChannelRecovery.immediate(parent: parent, outputIndex: UInt32(index),
                    destination: policy.script, feeSat: policy.feeSat, paymentSecret: channel.secrets.payment, format: channel.local.format),
                    delay: channel.local.format.hasAnchors ? 1 : 0)
            }
        }
        private func local(_ commitment: ChannelTransactions.Commitment, parent: Transaction) throws -> [Spend] {
            let point = try channel.secrets.point(commitment.parameters.number)
            let delayed = try ChannelKeys.derivedPrivateKey(baseSecret: channel.secrets.delayed, commitmentPoint: point)
            let htlcKey = try ChannelKeys.derivedPrivateKey(baseSecret: channel.secrets.htlc, commitmentPoint: point)
            var result = try delayedSpends(parent, commitment: commitment, secret: delayed)
            for (index, output) in commitment.htlcOutputs.enumerated() {
                guard index < channel.localHTLCSignatures.count else { throw LightningError.invalidCommitment }
                let preimage = preimages.first { ChannelKeys.hash($0) == output.htlc.paymentHash }
                if !output.htlc.offered && preimage == nil { continue }
                let signature = try ChannelKeys.sign(digest: ChannelRecovery.htlcDigest(commitment: commitment, output: output), secret: htlcKey)
                let stage = try ChannelRecovery.signedHTLC(commitment: commitment, output: output, localSignature: signature,
                    remoteSignature: channel.localHTLCSignatures[index], preimage: output.htlc.offered ? nil : preimage)
                result.append(Spend(stage, height: stage.locktime))
                // Anchor HTLC transactions permit added wallet inputs/change.
                // Their txid changes, while the channel input/output stay bound
                // by the peer's SINGLE|ANYONECANPAY signature.
                for mined in confirmed where mined.tx.inputs.contains(where: {
                    $0.previousOutput == stage.inputs[0].previousOutput
                }) {
                    result += try delayedSpends(mined.tx, commitment: commitment, secret: delayed)
                }
            }
            return result
        }
        private func delayedSpends(_ parent: Transaction, commitment: ChannelTransactions.Commitment, secret: Data) throws -> [Spend] {
            try parent.outputs.enumerated().compactMap { index, output in
                guard output.scriptPubKey == ChannelScripts.witnessScriptHash(commitment.delayedScript), policy.economic(output.value) else { return nil }
                let tx = try ChannelRecovery.delayed(parent: parent, outputIndex: UInt32(index), destination: policy.script,
                    feeSat: policy.feeSat, revocationKey: commitment.parameters.keys.revocation, delayedSecret: secret, delay: commitment.parameters.delay)
                return Spend(tx, delay: commitment.parameters.delay)
            }
        }
        private func remote(_ commitment: ChannelTransactions.Commitment) throws -> [Spend] {
            let point = try channel.commitmentPoint(localOwner: false, number: commitment.parameters.number)
            let key = try ChannelKeys.derivedPrivateKey(baseSecret: channel.secrets.htlc, commitmentPoint: point)
            return try commitment.htlcOutputs.compactMap { output in
                guard policy.economic(Int64(output.htlc.amountMsat / 1000)) else { return nil }
                let preimage = preimages.first { ChannelKeys.hash($0) == output.htlc.paymentHash }
                if output.htlc.offered && preimage == nil { return nil }
                let tx = try ChannelRecovery.remoteHTLC(commitment: commitment, output: output, destination: policy.script,
                    feeSat: policy.feeSat, htlcSecret: key, preimage: output.htlc.offered ? preimage : nil)
                return Spend(tx, delay: commitment.parameters.format.hasAnchors ? 1 : 0, height: tx.locktime)
            }
        }
        private func penalty(_ commitment: ChannelTransactions.Commitment, parent: Transaction) throws -> [Spend] {
            let secret = try ChannelKeys.revocationPrivateKey(baseSecret: channel.secrets.revocation,
                commitmentSecret: channel.revocations.secret(for: commitment.parameters.number))
            var result = try penaltyDelayed(parent, commitment: commitment, secret: secret)
            for output in commitment.htlcOutputs {
                if policy.economic(Int64(output.htlc.amountMsat / 1000)) {
                    result.append(Spend(try ChannelRecovery.penaltyHTLC(parent: parent, outputIndex: output.index, destination: policy.script,
                        feeSat: policy.feeSat, revocationSecret: secret, localKey: commitment.parameters.keys.htlcLocal,
                        remoteKey: commitment.parameters.keys.htlcRemote, htlc: output.htlc, format: channel.local.format)))
                }
                let outpoint = Transaction.Outpoint(txid: parent.txid, vout: output.index)
                for child in confirmed where child.tx.inputs.contains(where: { $0.previousOutput == outpoint }) {
                    result += try penaltyDelayed(child.tx, commitment: commitment, secret: secret)
                }
            }
            return result
        }
        private func penaltyDelayed(_ parent: Transaction, commitment: ChannelTransactions.Commitment, secret: Data) throws -> [Spend] {
            try parent.outputs.enumerated().compactMap { index, output in
                guard output.scriptPubKey == ChannelScripts.witnessScriptHash(commitment.delayedScript), policy.economic(output.value) else { return nil }
                return Spend(try ChannelRecovery.penaltyDelayed(parent: parent, outputIndex: UInt32(index), destination: policy.script,
                    feeSat: policy.feeSat, revocationSecret: secret, delayedKey: commitment.parameters.keys.delayedLocal, delay: commitment.parameters.delay))
            }
        }
    }
    private static func needsWalletFee(_ tx: Transaction) -> Bool {
        guard tx.inputs.count == 1 else { return false }
        let witness = tx.inputs[0].witness
        guard witness.count == 5 else { return false }
        return witness[1].last == 0x83 && witness[2].last == 0x83
    }
    static func available(_ spend: Spend, confirmed: [Confirmed], height: UInt32) throws -> Bool {
        let tx = try Transaction.decode(spend.transaction)
        // Anchor second stages require a reserved wallet fee input. Relay only
        // the already-authorized augmented transaction, including while locked.
        guard !needsWalletFee(tx), let input = tx.inputs.first, height >= spend.minimumHeight,
              try parentAvailable(spend, input: input, confirmed: confirmed, height: height) else { return false }
        let outpoints = Set(tx.inputs.map(\.previousOutput))
        return !confirmed.contains { $0.tx.inputs.contains { outpoints.contains($0.previousOutput) } }
    }
    private static func parentAvailable(_ spend: Spend, input: Transaction.Input, confirmed: [Confirmed], height: UInt32) throws -> Bool {
        if let parent = confirmed.first(where: { $0.tx.txid == input.previousOutput.txid }) {
            return UInt64(height) + 1 >= UInt64(parent.height) + UInt64(spend.relativeDelay)
        }
        // A pre-signed CPFP must relay together with its already-authorized
        // commitment, before confirmation. CSV/HTLC claims still wait for blocks.
        guard spend.relativeDelay == 0, let raw = spend.unconfirmedParent else { return false }
        return try Transaction.decode(raw).txid == input.previousOutput.txid
    }

}

extension ChannelState {
    func remoteCommitmentNumber(_ tx: Transaction) throws -> UInt64? {
        guard let remote, tx.inputs.count == 1, let input = tx.inputs.first,
              input.sequence & 0xff000000 == 0x80000000, tx.locktime & 0xff000000 == 0x20000000 else { return nil }
        let basepoints = isFunder ? local.payment + remote.payment : remote.payment + local.payment
        let obscurer = ChannelKeys.hash(basepoints).suffix(6).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return ((UInt64(input.sequence & 0xffffff) << 24) | UInt64(tx.locktime & 0xffffff)) ^ obscurer
    }
}
