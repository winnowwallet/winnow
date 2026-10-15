import Foundation
import P256K
import TestSupport
import VaultKit
import WalletCore

/// Offline development protocol for Tools/Satochip/run-recovery.py. Every key
/// and outpoint is a public test fixture. This never opens a user's wallet,
/// contacts peers, accesses iCloud, or sends commands to a card.
enum SatochipRecovery {
    static let chainTip: UInt32 = 1_000
    static let coordinates = [Vault.OutputCoordinate(choice: 1, index: 3)]

    static func run() async throws {
        let (vault, masters) = try TestVaults.muSig2Vault()
        let words = try BIP39.mnemonic(entropy: Data(repeating: 0xA1, count: 16))
        let cardWords = try BIP39.mnemonic(entropy: Data(repeating: 0xB2, count: 16))
        let cardKey = try masters[1].derived(path: "m/86'/1'/0'").publicKey
        let script = try vault.scriptPubKey(index: 2, choice: 0)
        try send(["action": "fixture", "network": "signet", "test_keys_only": true,
                  "card_seed": try BIP39.seed(mnemonic: cardWords).hex,
                  "card_path": "m/86'/1'/0'", "card_public_key": cardKey.hex,
                  "funding_script": script.hex])
        let funding = try receive()
        let coin: WalletUTXO
        if funding["private_regtest"] as? Bool == true,
           let vout = funding["vout"] as? UInt32 {
            let txid = try bytes("txid", in: funding, count: 32)
            coin = WalletUTXO(txid: Data(txid.reversed()), vout: vout, amount: 80_000,
                             scriptPubKey: script, chain: .receive, index: 2, height: chainTip)
        } else {
            try require(funding.isEmpty, "unexpected funding input")
            coin = try TestVaults.funding(vault: vault, amount: 80_000, index: 2)
        }
        let original = try Wallet.create(network: .signet, keyStore: InMemoryKeyStore(),
                                          entropy: Data(repeating: 0xA1, count: 16), creationHeight: chainTip + 1)
        for _ in 0..<4 { _ = try await original.freshReceiveAddress() }
        var backup = try await original.exportBundle(includeMnemonic: true)
        backup.nextChangeIndex = 2
        let descriptor = vault.descriptor.serialized()
        backup.vaults = [VaultRecord(id: String(descriptor.split(separator: "#").last!), name: "Satochip fixture",
                                     descriptor: descriptor, createdAtHeight: 100,
                                     nextReceiveIndex: 5, nextChangeIndex: 3, allUtxos: [coin])]
        let saved = try JSONEncoder().encode(backup)
        var watchOnly = backup
        watchOnly.mnemonic = nil
        let watching = try Wallet.importing(watchOnly, keyStore: InMemoryKeyStore())
        var missingWordsRejected = false
        do { _ = try await watching.exportBundle(includeMnemonic: true) }
        catch { missingWordsRejected = true }
        try require(missingWordsRejected, "watch-only backup unexpectedly restored a signing key")
        var wrongWords = backup
        wrongWords.mnemonic = try BIP39.mnemonic(entropy: Data(repeating: 0xC3, count: 16))
        var wrongWordsRejected = false
        do { _ = try Wallet.importing(wrongWords, keyStore: InMemoryKeyStore()) }
        catch { wrongWordsRejected = true }
        try require(wrongWordsRejected, "wrong recovery words accepted")

        for scenario in ["baseline", "phone-restored", "card-restored", "both-restored"] {
            let decoded = try ImportBundle.decode(json: String(decoding: saved, as: UTF8.self))
            let keys = InMemoryKeyStore()
            let wallet = try Wallet.importing(decoded, keyStore: keys)
            let exported = try await wallet.exportBundle(includeMnemonic: true)
            try require(exported.mnemonic == words, "phone key failed to restore")
            try require(exported.nextReceiveIndex == 4 && exported.nextChangeIndex == 2,
                        "ordinary wallet counters changed")
            guard let record = decoded.vaults?.first else { throw Failure.invalid("account missing") }
            try require(record == backup.vaults?.first, "account backup changed")
            let restored = try Vault(record.descriptor, network: .signet)
            let phone = scenario.contains("phone") || scenario == "both-restored"
                ? try HDKey(seed: BIP39.seed(mnemonic: exported.mnemonic!)) : masters[0]
            try sign(scenario: scenario, vault: restored, record: record, phone: phone, cardKey: cardKey)
        }
        try send(["action": "complete", "scenarios": 4, "network_broadcast": false,
                  "watch_only_key_restore_rejected": true, "wrong_phone_words_rejected": true])
    }

    private static func sign(scenario: String, vault: Vault, record: VaultRecord,
                             phone: HDKey, cardKey: Data) throws {
        let coin = record.utxos[0]
        let context = try vault.muSig2Context(choice: coin.chain.rawValue, index: coin.index)
        let destination = Data([0x51, 0x20]) + Data(repeating: 0x42, count: 32)
        var proposal = try vault.createSpend(utxos: record.utxos,
                                             payments: [Payment(amount: 50_000, scriptPubKey: destination)],
                                             changeIndex: record.nextChangeIndex,
                                             feeRateSatPerVByte: 2, chainTip: chainTip, randomness: { 0.5 })
        var phoneNonces = try vault.muSig2AttachNonce(
            &proposal, input: 0, context: context, master: phone,
            knownUTXOs: record.utxos, ownedOutputCoordinates: coordinates, chainTip: chainTip)
        let message = try vault.keyPathSighash(proposal, input: 0)
        try send(["action": "nonce", "scenario": scenario, "aggregate_key": context.outputKey.hex,
                  "message": message.hex])
        let response = try receive()
        let wireNonce = try bytes("public_nonce", in: response, count: 68)
        // v0.15-0.1 appends a two-byte slot ID. It is not part of BIP373.
        try require(wireNonce.suffix(2) != Data([0, 0]), "card returned a reserved nonce ID")
        let nonce = Data(wireNonce.prefix(66))
        let id = PSBT.MuSig2KeyID(participant: cardKey, aggregate: context.signingKey)
        try proposal.attachMuSig2PubNonce(input: 0, id: id, nonce: nonce)
        let session = try proposal.muSig2Session(input: 0, aggregateKey: context.aggregate,
                                                tweaks: context.tweaks, isXOnlyTweaks: context.isXOnlyTweaks,
                                                message: message)
        let parameters = try MuSig.partialSignParameters(publicKey: cardKey, session: session)
        try vault.muSig2Sign(&proposal, input: 0, context: context, master: phone,
                             secretNonces: &phoneNonces, knownUTXOs: record.utxos,
                             ownedOutputCoordinates: coordinates, chainTip: chainTip)
        var missingSignerRejected = false
        do {
            var incomplete = proposal
            try vault.muSig2Aggregate(&incomplete, input: 0, context: context,
                                      knownUTXOs: record.utxos, ownedOutputCoordinates: coordinates,
                                      chainTip: chainTip)
        } catch { missingSignerRejected = true }
        try require(missingSignerRejected, "phone signed without the card")
        try send(["action": "sign", "scenario": scenario, "b": parameters.nonceCoefficient.hex,
                  "ea": parameters.challengeTimesKeyCoefficient.hex,
                  "r_has_even_y": !parameters.negateNonces, "ggacc_is_1": !parameters.negateSecretKey])
        let partial = try bytes("partial_signature", in: receive(), count: 32)
        try require(try MuSig.partialVerify(partialSignature: partial, publicNonce: nonce,
                                           publicKey: cardKey, session: session), "invalid card partial")
        var changed = session
        changed.message[0] ^= 1
        try require(try !MuSig.partialVerify(partialSignature: partial, publicNonce: nonce,
                                            publicKey: cardKey, session: changed), "partial accepted for changed payment")
        var missingPhoneRejected = false
        do {
            var cardOnly = proposal
            cardOnly.inputs[0].musig2PartialSigs = [id: partial]
            try vault.muSig2Aggregate(&cardOnly, input: 0, context: context,
                                      knownUTXOs: record.utxos, ownedOutputCoordinates: coordinates, chainTip: chainTip)
        } catch { missingPhoneRejected = true }
        try require(missingPhoneRejected, "card signed without the phone")
        proposal.inputs[0].musig2PartialSigs[id] = partial
        try vault.muSig2Aggregate(&proposal, input: 0, context: context, knownUTXOs: record.utxos,
                                  ownedOutputCoordinates: coordinates, chainTip: chainTip)
        let transaction = try vault.finalizeSpend(&proposal, knownUTXOs: record.utxos,
                                                  ownedOutputCoordinates: coordinates, chainTip: chainTip)
        let signature = try P256K.Schnorr.SchnorrSignature(dataRepresentation: transaction.inputs[0].witness[0])
        var signingMessage = [UInt8](message)
        try require(P256K.Schnorr.XonlyKey(dataRepresentation: context.outputKey)
            .isValid(signature, for: &signingMessage), "final signature invalid")
        try send(["action": "result", "scenario": scenario, "signature_verified": true,
                  "single_signer_rejected": true, "changed_payment_rejected": true,
                  "missing_phone_rejected": true,
                  "account_backup_roundtrip": true,
                  "transaction_hex": transaction.serialized(includeWitness: true).hex])
    }

    private static func send(_ value: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        data.append(0x0A)
        try FileHandle.standardOutput.write(contentsOf: data)
    }

    private static func receive() throws -> [String: Any] {
        guard let line = readLine(), line.utf8.count <= 4_096,
              let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        else { throw Failure.invalid("invalid development-driver response") }
        return object
    }

    private static func bytes(_ key: String, in object: [String: Any], count: Int) throws -> Data {
        guard let text = object[key] as? String, let data = Data(hex: text), data.count == count else {
            throw Failure.invalid("invalid \(key)")
        }
        return data
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure.invalid(message) }
    }

    enum Failure: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self { case let .invalid(message): message }
        }
    }
}
