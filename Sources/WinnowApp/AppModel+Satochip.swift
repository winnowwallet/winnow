import Foundation
import WalletCore

/// A Satochip card as one signer of a raw MuSig2 account. Each card step is
/// one tap: the card is opened with its PIN, derives the registered key, and
/// is checked to be this account's card before it is asked for anything.
/// The card's 2FA approvals come from the checker as pasted text; the phone
/// never holds the card's seed or its 2FA secret.
extension AppModel {
    /// The card reader: Core NFC, or in E2E runs the runner's loopback card.
    var satochipReader: any SatochipReader {
        #if DEBUG
        if let port = e2e?.satochipPort { return LoopbackSatochipReader(port: port) }
        #endif
        return CoreNFCSatochipReader()
    }

    /// Where the card derives its participant key: BIP86 account 0, like
    /// this phone's own key.
    var satochipParticipantPath: [UInt32] {
        [86 + HDKey.hardenedOffset, (network == .mainnet ? 0 : 1) + HDKey.hardenedOffset, HDKey.hardenedOffset]
    }

    /// One tap: the card's participant key with its origin.
    func readSatochipKey(pin: String) async throws -> Satochip.ParticipantKey {
        let path = satochipParticipantPath
        let pin = Data(pin.utf8)
        let key = try await satochipReader.withCard("Hold your Satochip near the top of the iPhone.") { transport in
            var session = Satochip.Session(transport: transport)
            try await session.connect(pin: pin)
            return try await session.participantKey(path: path)
        }
        e2e?.journal("musig2.satochipKeyRead", fields: ["key": key.keyExpression(network: hdKeyNetwork)])
        return key
    }

    var hdKeyNetwork: HDKey.Network { network == .mainnet ? .mainnet : .testnet }

    /// The descriptor of a 2-of-2 between this phone and the card.
    func muSig2Descriptor(withSatochip key: Satochip.ParticipantKey) throws -> String {
        "tr(musig(\(try muSig2KeyExpression()),\(key.keyExpression(network: hdKeyNetwork)))/<0;1>/*)"
    }

    /// Round 1 for the card: one tap for its nonce on every input.
    func attachSatochipNonces(_ psbt: PSBT, record: MuSig2AccountRecord, pin: String) async throws
        -> (psbt: PSBT, nonces: [Int: Satochip.CardNonce]) {
        guard let card = record.satochip else { throw MuSig2ActionError.noSatochip }
        let account = try muSig2Account(for: record)
        let requests = try account.cardNonceRequests(psbt, participant: card.accountKey, knownUTXOs: record.utxos,
                                                     ownedOutputCoordinates: muSig2OwnedCoordinates(for: record),
                                                     chainTip: status.tipHeight)
        let pin = Data(pin.utf8)
        let nonces = try await satochipReader.withCard("Hold your Satochip near the top of the iPhone to add its nonce.") {
            transport in
            var session = try await Self.openSatochip(transport, pin: pin, card: card)
            var nonces: [Int: Satochip.CardNonce] = [:]
            for request in requests {
                nonces[request.input] = try await session.generateNonce(aggregateKey: request.aggregateKey,
                                                                        message: request.message)
            }
            return nonces
        }
        var updated = psbt
        try account.attachCardNonces(&updated, participant: card.accountKey,
                                     publicNonces: nonces.mapValues(\.publicNonce), knownUTXOs: record.utxos)
        journalPSBT(stage: "musig2-card-nonces", psbt: updated)
        return (updated, nonces)
    }

    /// Round 2 for the card: one tap for its partial signature on every
    /// input, each checked before the PSBT carries it. With the card's 2FA on,
    /// `approvals` are the checker's for this exact payment.
    func signWithSatochip(_ psbt: PSBT, record: MuSig2AccountRecord, pin: String,
                          nonces: [Int: Satochip.CardNonce], approvals: Satochip.Approvals?) async throws -> PSBT {
        guard let card = record.satochip else { throw MuSig2ActionError.noSatochip }
        let account = try muSig2Account(for: record)
        let coordinates = muSig2OwnedCoordinates(for: record)
        let requests = try account.cardSignatureRequests(psbt, participant: card.accountKey, knownUTXOs: record.utxos,
                                                         ownedOutputCoordinates: coordinates,
                                                         chainTip: status.tipHeight)
        if let approvals, approvals.txid != (try psbt.unsignedTransaction().txid.displayHex) {
            throw MuSig2ActionError.approvalsForAnotherPayment
        }
        var blobs: [Int: Data] = [:]
        for request in requests {
            guard let nonce = nonces[request.input] else { throw MuSig2ActionError.cardNonceMissing }
            blobs[request.input] = nonce.encryptedSecretNonce
        }
        let pin = Data(pin.utf8)
        let partials = try await satochipReader.withCard("Hold your Satochip near the top of the iPhone to sign.") {
            [blobs] transport in
            var session = try await Self.openSatochip(transport, pin: pin, card: card)
            var partials: [Int: Data] = [:]
            for request in requests {
                partials[request.input] = try await session.partialSign(
                    encryptedSecretNonce: blobs[request.input]!, signingContext: request.signingContext,
                    approval: approvals?.byInput[request.input])
            }
            return partials
        }
        var updated = psbt
        try account.attachCardPartialSignatures(&updated, participant: card.accountKey, partialSignatures: partials,
                                                knownUTXOs: record.utxos, ownedOutputCoordinates: coordinates,
                                                chainTip: status.tipHeight)
        journalPSBT(stage: "musig2-card-signed", psbt: updated)
        return updated
    }

    /// Connect with the PIN, derive the registered key, and refuse any other card.
    nonisolated static func openSatochip(_ transport: any SatochipTransport, pin: Data,
                                         card: SatochipRegistration) async throws -> Satochip.Session {
        var session = Satochip.Session(transport: transport)
        try await session.connect(pin: pin)
        let (x, _) = try await session.derive(path: card.path)
        guard x == card.accountKey.dropFirst() else { throw MuSig2ActionError.wrongSatochip }
        return session
    }
}
