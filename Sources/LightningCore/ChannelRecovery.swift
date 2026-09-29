import Foundation
import WalletCore

/// BOLT 3 on-chain resolution for negotiated commitment formats.
/// These builders authorize no broadcast: the caller must select the current
/// commitment and obtain height/confirmation information from Winnow's chain.
public enum ChannelRecovery {
    /// The non-owner's immediate static_remotekey output.
    public static func immediate(parent: Transaction, outputIndex: UInt32, destination: Script,
                                 feeSat: UInt64, paymentSecret: Data, format: ChannelFormat = .staticRemoteKey) throws -> Transaction {
        let key = try ChannelKeys.publicKey(secret: paymentSecret)
        guard parent.outputs.indices.contains(Int(outputIndex)) else { throw LightningError.invalidCommitment }
        let output = parent.outputs[Int(outputIndex)]
        guard output.scriptPubKey == (try ChannelScripts.remoteOutput(paymentKey: key, format: format)), output.value > 0,
              feeSat < UInt64(output.value) else { throw LightningError.invalidAmount }
        let hash = RIPEMD160.hash(ChannelKeys.hash(key))
        let script = try format.hasAnchors ? ChannelScripts.remote(paymentKey: key)
            : Script.build { $0.appendOpcode(0x76); $0.appendOpcode(0xa9); $0.appendPush(hash); $0.appendOpcode(0x88); $0.appendOpcode(0xac) }
        var tx = Transaction(version: 2, inputs: [.init(previousOutput: .init(txid: parent.txid, vout: outputIndex),
            scriptSig: Data(), sequence: format.hasAnchors ? 1 : .max)], outputs: [.init(value: output.value - Int64(feeSat), scriptPubKey: destination.bytes)], locktime: 0)
        let digest = try SighashBIP143.sighash(tx: tx, inputIndex: 0, scriptCode: script.bytes, value: output.value)
        let signature = try ChannelKeys.sign(digest: digest, secret: paymentSecret) + Data([1])
        tx.inputs[0].witness = format.hasAnchors ? [signature, script.bytes] : [signature, key]
        return tx
    }

    /// A non-owner claims the single-signature branch on the peer's commitment.
    public static func remoteHTLC(commitment: ChannelTransactions.Commitment, output: ChannelTransactions.HTLCOutput,
                                  destination: Script, feeSat: UInt64, htlcSecret: Data, preimage: Data? = nil) throws -> Transaction {
        guard try ChannelKeys.publicKey(secret: htlcSecret) == commitment.parameters.keys.htlcRemote,
              commitment.htlcOutputs.contains(where: { $0.index == output.index && $0.htlc == output.htlc }),
              feeSat < output.htlc.amountMsat / 1000 else { throw LightningError.invalidCommitment }
        let selector: Data
        if output.htlc.offered {
            guard let preimage, preimage.count == 32, ChannelKeys.hash(preimage) == output.htlc.paymentHash else { throw LightningError.invalidHash }
            selector = preimage
        } else {
            guard preimage == nil else { throw LightningError.invalidHash }
            selector = Data()
        }
        var tx = Transaction(version: 2, inputs: [.init(previousOutput: .init(txid: commitment.transaction.txid, vout: output.index),
            scriptSig: Data(), sequence: commitment.parameters.format.htlcSequence)], outputs: [.init(value: Int64(output.htlc.amountMsat / 1000 - feeSat), scriptPubKey: destination.bytes)],
            locktime: output.htlc.offered ? 0 : output.htlc.expiry)
        let digest = try SighashBIP143.sighash(tx: tx, inputIndex: 0, scriptCode: output.witnessScript.bytes,
                                             value: Int64(output.htlc.amountMsat / 1000))
        tx.inputs[0].witness = [try ChannelKeys.sign(digest: digest, secret: htlcSecret) + Data([1]), selector, output.witnessScript.bytes]
        return tx
    }
    public static func htlcDigest(commitment: ChannelTransactions.Commitment,
                                  output: ChannelTransactions.HTLCOutput) throws -> Data {
        let tx = try ChannelTransactions.htlcTransaction(commitment: commitment, output: output)
        return try SighashBIP143.sighash(tx: tx, inputIndex: 0, scriptCode: output.witnessScript.bytes,
                                      value: Int64(output.htlc.amountMsat / 1000), hashType: commitment.parameters.format.htlcSighash)
    }

    /// HTLC-timeout for an offered output; HTLC-success for a received output.
    /// Signatures exclude the sighash byte and use the derived HTLC keys.
    public static func signedHTLC(commitment: ChannelTransactions.Commitment,
                                  output: ChannelTransactions.HTLCOutput, localSignature: Data,
                                  remoteSignature: Data, preimage: Data? = nil) throws -> Transaction {
        let keys = commitment.parameters.keys
        let script = try ChannelScripts.htlc(offered: output.htlc.offered, revocation: keys.revocation,
            local: keys.htlcLocal, remote: keys.htlcRemote, paymentHash: output.htlc.paymentHash, expiry: output.htlc.expiry, format: commitment.parameters.format)
        guard script == output.witnessScript else { throw LightningError.invalidCommitment }
        let digest = try htlcDigest(commitment: commitment, output: output)
        guard ChannelKeys.verify(signature: localSignature, digest: digest, publicKey: keys.htlcLocal),
              ChannelKeys.verify(signature: remoteSignature, digest: digest, publicKey: keys.htlcRemote)
        else { throw LightningError.invalidSignature }
        let branch = try htlcBranch(output.htlc, preimage: preimage)
        var tx = try ChannelTransactions.htlcTransaction(commitment: commitment, output: output)
        let hashByte = Data([UInt8(commitment.parameters.format.htlcSighash.rawValue)])
        tx.inputs[0].witness = [Data(), remoteSignature + hashByte, localSignature + hashByte, branch, script.bytes]
        return tx
    }

    public static func delayed(parent: Transaction, outputIndex: UInt32, destination: Script, feeSat: UInt64,
                               revocationKey: Data, delayedSecret: Data, delay: UInt16) throws -> Transaction {
        let script = try ChannelScripts.delayed(revocation: revocationKey,
            delayed: ChannelKeys.publicKey(secret: delayedSecret), delay: delay)
        return try spend(parent, outputIndex, destination, feeSat, script: script,
                         secret: delayedSecret, sequence: UInt32(delay), selector: Data())
    }

    public static func penaltyDelayed(parent: Transaction, outputIndex: UInt32, destination: Script, feeSat: UInt64,
                                      revocationSecret: Data, delayedKey: Data, delay: UInt16) throws -> Transaction {
        let script = try ChannelScripts.delayed(revocation: ChannelKeys.publicKey(secret: revocationSecret),
                                                delayed: delayedKey, delay: delay)
        return try spend(parent, outputIndex, destination, feeSat, script: script,
                         secret: revocationSecret, sequence: 0xffffffff, selector: Data([1]))
    }

    public static func penaltyHTLC(parent: Transaction, outputIndex: UInt32, destination: Script, feeSat: UInt64,
                                   revocationSecret: Data, localKey: Data, remoteKey: Data,
                                   htlc: ChannelTransactions.HTLC, format: ChannelFormat = .staticRemoteKey) throws -> Transaction {
        let key = try ChannelKeys.publicKey(secret: revocationSecret)
        let script = try ChannelScripts.htlc(offered: htlc.offered, revocation: key,
            local: localKey, remote: remoteKey, paymentHash: htlc.paymentHash, expiry: htlc.expiry, format: format)
        return try spend(parent, outputIndex, destination, feeSat, script: script,
                         secret: revocationSecret, sequence: 0xffffffff, selector: key)
    }

    private static func htlcBranch(_ htlc: ChannelTransactions.HTLC, preimage: Data?) throws -> Data {
        if htlc.offered {
            guard preimage == nil else { throw LightningError.invalidHash }
            return Data()
        }
        guard let preimage, preimage.count == 32, ChannelKeys.hash(preimage) == htlc.paymentHash else {
            throw LightningError.invalidHash
        }
        return preimage
    }

    private static func spend(_ parent: Transaction, _ index: UInt32, _ destination: Script, _ fee: UInt64,
                              script: Script, secret: Data, sequence: UInt32, selector: Data) throws -> Transaction {
        guard parent.outputs.indices.contains(Int(index)) else { throw LightningError.invalidCommitment }
        let output = parent.outputs[Int(index)]
        guard output.scriptPubKey == ChannelScripts.witnessScriptHash(script) else { throw LightningError.invalidCommitment }
        guard output.value > 0, output.value <= 2_100_000_000_000_000,
              fee < UInt64(output.value), !destination.bytes.isEmpty else { throw LightningError.invalidAmount }
        var tx = Transaction(version: 2, inputs: [.init(previousOutput: .init(txid: parent.txid, vout: index),
            scriptSig: Data(), sequence: sequence)], outputs: [.init(value: output.value - Int64(fee),
            scriptPubKey: destination.bytes)], locktime: 0)
        let digest = try SighashBIP143.sighash(tx: tx, inputIndex: 0, scriptCode: script.bytes, value: output.value)
        tx.inputs[0].witness = [try ChannelKeys.sign(digest: digest, secret: secret) + Data([1]), selector, script.bytes]
        return tx
    }
}
