import CryptoKit
import Foundation
import LightningCore
import WalletCore

// Disposable regtest fixture only. Public, deterministic test keys must never
// reach the application. Core supplies test coins; Swift constructs and signs
// every channel and resolution transaction using the production module.
enum Fixture {
    static func secret(_ byte: UInt8) -> Data { Data(repeating: byte, count: 32) }
    static func key(_ byte: UInt8) throws -> Data { try ChannelKeys.publicKey(secret: secret(byte)) }
    static let delay: UInt16 = 6
    static let feePerKW: UInt32 = 1000

    static func run() throws -> [String: String] {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["bolt12"] { return try offerVectors() }
        if arguments == ["onion-reply"] { return try onionReply() }
        if arguments.first == "augment-htlc" { return try augmentHTLC(arguments) }
        let funding = try ChannelScripts.funding(key(1), key(2))
        if arguments == ["script"] {
            return ["script": funding.bytes.hex, "local": try key(1).hex, "remote": try key(2).hex]
        }
        guard arguments.count == 4, ["transactions", "anchor-transactions"].contains(arguments[0]),
              let raw = Data(hex: arguments[1]), let destination = Data(hex: arguments[2]),
              let expiry = UInt32(arguments[3]) else { throw LightningError.invalidMessage }
        let transaction = try Transaction.decode(raw)
        let matches = transaction.outputs.indices.filter {
            transaction.outputs[$0].value == 100_000 && transaction.outputs[$0].scriptPubKey == ChannelScripts.witnessScriptHash(funding)
        }
        guard matches.count == 1, let index = matches.first else { throw LightningError.invalidCommitment }
        return try transactions(outpoint: .init(txid: transaction.txid, vout: UInt32(index)),
                                destination: Script(destination), expiry: expiry, format: arguments[0] == "anchor-transactions" ? .anchors : .staticRemoteKey)
    }

    static func transactions(outpoint: Transaction.Outpoint, destination: Script, expiry: UInt32, format: ChannelFormat = .staticRemoteKey) throws -> [String: String] {
        let point = try key(8)
        let delayedSecret = try ChannelKeys.derivedPrivateKey(baseSecret: secret(4), commitmentPoint: point)
        let revocationSecret = try ChannelKeys.revocationPrivateKey(baseSecret: secret(3), commitmentSecret: secret(8))
        let localHTLC = try ChannelKeys.derivedPrivateKey(baseSecret: secret(5), commitmentPoint: point)
        let remoteHTLC = try ChannelKeys.derivedPrivateKey(baseSecret: secret(6), commitmentPoint: point)
        let keys = try ChannelTransactions.Keys(fundingLocal: key(1), fundingRemote: key(2),
            revocation: ChannelKeys.publicKey(secret: revocationSecret), delayedLocal: ChannelKeys.publicKey(secret: delayedSecret),
            paymentRemote: key(7), htlcLocal: ChannelKeys.publicKey(secret: localHTLC), htlcRemote: ChannelKeys.publicKey(secret: remoteHTLC))
        let htlcs = [ChannelTransactions.HTLC(id: 0, offered: true, amountMsat: 2_000_000,
                         paymentHash: Data(SHA256.hash(data: secret(9))), expiry: expiry),
                     ChannelTransactions.HTLC(id: 0, offered: false, amountMsat: 4_000_000,
                         paymentHash: Data(SHA256.hash(data: secret(10))), expiry: expiry)]
        let parameters = try ChannelTransactions.Parameters(funding: outpoint, fundingSat: 100_000,
            localMsat: 55_000_000, remoteMsat: 39_000_000, localIsFunder: true, dustSat: 546,
            feePerKW: feePerKW, delay: delay, number: 0, openerPaymentBasepoint: key(11),
            accepterPaymentBasepoint: key(7), keys: keys, format: format, htlcs: htlcs)
        let commitment = try ChannelTransactions.commitment(parameters)
        let digest = try ChannelTransactions.fundingDigest(commitment)
        let signed = try ChannelTransactions.signed(commitment,
            localSignature: ChannelKeys.sign(digest: digest, secret: secret(1)),
            remoteSignature: ChannelKeys.sign(digest: digest, secret: secret(2)))
        guard let delayedIndex = signed.outputs.firstIndex(where: {
            $0.scriptPubKey == ChannelScripts.witnessScriptHash(commitment.delayedScript)
        }) else { throw LightningError.invalidCommitment }
        var result = ["commitment": signed.serialized(includeWitness: true).hex, "format": format.rawValue]
        var invalid = signed
        invalid.outputs[0].value += 1
        result["invalid_commitment"] = invalid.serialized(includeWitness: true).hex
        result["delayed"] = try ChannelRecovery.delayed(parent: signed, outputIndex: UInt32(delayedIndex),
            destination: destination, feeSat: 500, revocationKey: keys.revocation, delayedSecret: delayedSecret, delay: delay)
            .serialized(includeWitness: true).hex
        result["penalty_delayed"] = try ChannelRecovery.penaltyDelayed(parent: signed, outputIndex: UInt32(delayedIndex),
            destination: destination, feeSat: 500, revocationSecret: revocationSecret, delayedKey: keys.delayedLocal, delay: delay)
            .serialized(includeWitness: true).hex
        if let immediate = signed.outputs.firstIndex(where: { $0.scriptPubKey == (try? ChannelScripts.remoteOutput(paymentKey: key(7), format: format)) }) {
            result["remote_immediate"] = try ChannelRecovery.immediate(parent: signed, outputIndex: UInt32(immediate),
                destination: destination, feeSat: 500, paymentSecret: secret(7), format: format).serialized(includeWitness: true).hex
        }
        for output in commitment.htlcOutputs {
            let name = output.htlc.offered ? "timeout" : "success"
            let digest = try ChannelRecovery.htlcDigest(commitment: commitment, output: output)
            let stage = try ChannelRecovery.signedHTLC(commitment: commitment, output: output,
                localSignature: ChannelKeys.sign(digest: digest, secret: localHTLC),
                remoteSignature: ChannelKeys.sign(digest: digest, secret: remoteHTLC),
                preimage: output.htlc.offered ? nil : secret(10))
            result[name] = stage.serialized(includeWitness: true).hex
            result[name + "_delayed"] = try ChannelRecovery.delayed(parent: stage, outputIndex: 0,
                destination: destination, feeSat: 500, revocationKey: keys.revocation, delayedSecret: delayedSecret, delay: delay)
                .serialized(includeWitness: true).hex
            result["penalty_" + name] = try ChannelRecovery.penaltyHTLC(parent: signed, outputIndex: output.index,
                destination: destination, feeSat: 500, revocationSecret: revocationSecret,
                localKey: keys.htlcLocal, remoteKey: keys.htlcRemote, htlc: output.htlc, format: format).serialized(includeWitness: true).hex
            result[output.htlc.offered ? "remote_success" : "remote_timeout"] = try ChannelRecovery.remoteHTLC(
                commitment: commitment, output: output, destination: destination, feeSat: 500,
                htlcSecret: remoteHTLC, preimage: output.htlc.offered ? secret(9) : nil).serialized(includeWitness: true).hex
            result["penalty_stage_" + name] = try ChannelRecovery.penaltyDelayed(parent: stage, outputIndex: 0,
                destination: destination, feeSat: 500, revocationSecret: revocationSecret, delayedKey: keys.delayedLocal,
                delay: delay).serialized(includeWitness: true).hex
        }
        return result
    }
}

do {
    let json = try JSONSerialization.data(withJSONObject: Fixture.run(), options: [.sortedKeys])
    FileHandle.standardOutput.write(json + Data([10]))
} catch {
    FileHandle.standardError.write(Data("Lightning fixture failed: \(error)\n".utf8))
    exit(1)
}
