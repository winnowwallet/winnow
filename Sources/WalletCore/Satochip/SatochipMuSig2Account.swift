import Foundation

/// A Satochip card as one participant of a raw MuSig2 account. The phone
/// coordinates: it computes what the card needs from the PSBT, sends it over
/// a card session, and verifies what comes back before the PSBT carries it.
/// Every step reviews the spend first, as the phone's own rounds do.
extension MuSig2Account {
    /// A card holds 16 outstanding nonces, so it signs at most 16 inputs per spend.
    public static let maximumCardInputs = 16

    /// What the card's NonceGen takes for one input.
    public struct CardNonceRequest: Equatable, Sendable {
        public let input: Int
        /// The input's x-only output key (BIP327 aggpk).
        public let aggregateKey: Data
        /// The input's BIP341 key-path sighash.
        public let message: Data
    }

    /// What the card's Sign takes for one input, and what the checker approves.
    public struct CardSignatureRequest: Equatable, Sendable {
        public let input: Int
        public let signingContext: Data
    }

    /// Round 1 for the card participant `participant` (its compressed key).
    public func cardNonceRequests(_ psbt: PSBT, participant: Data, knownUTXOs: [WalletUTXO],
                                  ownedOutputCoordinates: [OutputCoordinate],
                                  chainTip: UInt32) throws -> [CardNonceRequest] {
        _ = try reviewSpend(psbt, knownUTXOs: knownUTXOs, ownedOutputCoordinates: ownedOutputCoordinates,
                            chainTip: chainTip)
        guard psbt.inputs.count <= Self.maximumCardInputs else {
            throw MuSig2AccountError.invalidSpend("a Satochip signs at most \(Self.maximumCardInputs) inputs per spend")
        }
        return try psbt.inputs.indices.map { input in
            let utxo = try coin(for: psbt, input: input, knownUTXOs: knownUTXOs)
            let context = try muSig2Context(choice: utxo.chain.rawValue, index: utxo.index)
            guard context.participants.contains(participant) else { throw MuSig2AccountError.noParticipantKey(input: input) }
            return CardNonceRequest(input: input, aggregateKey: context.outputKey,
                                    message: try keyPathSighash(psbt, input: input))
        }
    }

    /// Attaches the card's public nonces (BIP373) by input.
    public func attachCardNonces(_ psbt: inout PSBT, participant: Data, publicNonces: [Int: Data],
                                 knownUTXOs: [WalletUTXO]) throws {
        for (input, nonce) in publicNonces.sorted(by: { $0.key < $1.key }) {
            let utxo = try coin(for: psbt, input: input, knownUTXOs: knownUTXOs)
            let context = try muSig2Context(choice: utxo.chain.rawValue, index: utxo.index)
            guard context.participants.contains(participant) else { throw MuSig2AccountError.noParticipantKey(input: input) }
            try psbt.attachMuSig2PubNonce(input: input,
                                          id: PSBT.MuSig2KeyID(participant: participant, aggregate: context.signingKey),
                                          nonce: nonce)
        }
    }

    /// Round 2 for the card, once every participant attached a nonce: the
    /// signing context per input.
    public func cardSignatureRequests(_ psbt: PSBT, participant: Data, knownUTXOs: [WalletUTXO],
                                      ownedOutputCoordinates: [OutputCoordinate],
                                      chainTip: UInt32) throws -> [CardSignatureRequest] {
        _ = try reviewSpend(psbt, knownUTXOs: knownUTXOs, ownedOutputCoordinates: ownedOutputCoordinates,
                            chainTip: chainTip)
        return try psbt.inputs.indices.map { input in
            let (session, _) = try cardSession(psbt, input: input, knownUTXOs: knownUTXOs)
            return CardSignatureRequest(input: input,
                                        signingContext: try Satochip.signingContext(publicKey: participant,
                                                                                    session: session))
        }
    }

    /// Verifies each of the card's partial signatures against its nonce and
    /// key, then attaches it.
    public func attachCardPartialSignatures(_ psbt: inout PSBT, participant: Data, partialSignatures: [Int: Data],
                                            knownUTXOs: [WalletUTXO], ownedOutputCoordinates: [OutputCoordinate],
                                            chainTip: UInt32) throws {
        _ = try reviewSpend(psbt, knownUTXOs: knownUTXOs, ownedOutputCoordinates: ownedOutputCoordinates,
                            chainTip: chainTip)
        for (input, partial) in partialSignatures.sorted(by: { $0.key < $1.key }) {
            let (session, context) = try cardSession(psbt, input: input, knownUTXOs: knownUTXOs)
            try psbt.attachMuSig2PartialSignature(
                input: input, id: PSBT.MuSig2KeyID(participant: participant, aggregate: context.signingKey),
                partialSignature: partial, session: session)
        }
    }

    private func cardSession(_ psbt: PSBT, input: Int,
                             knownUTXOs: [WalletUTXO]) throws -> (MuSig.Session, MuSig2Context) {
        let utxo = try coin(for: psbt, input: input, knownUTXOs: knownUTXOs)
        let context = try muSig2Context(choice: utxo.chain.rawValue, index: utxo.index)
        let session = try psbt.muSig2Session(input: input, aggregateKey: context.aggregate, tweaks: context.tweaks,
                                             isXOnlyTweaks: context.isXOnlyTweaks,
                                             message: keyPathSighash(psbt, input: input))
        return (session, context)
    }

    /// The participant that is this card's key, by its account public key.
    public func participant(forCardKey accountKey: Data) -> Descriptor.SingleKey? {
        participants.first {
            if case let .extended(base, _) = $0.base { return base.publicKey == accountKey }
            return false
        }
    }
}

extension Satochip {
    /// The checker's approvals for one spend, as text the phone pastes:
    /// `winnow-satochip-approvals 1 <txid>` and one `<input> <hex>` line per
    /// input. The txid lets the phone tell approvals for another payment
    /// apart; the card checks each approval against its own context anyway.
    public struct Approvals: Equatable, Sendable {
        public static let header = "winnow-satochip-approvals 1"

        /// The unsigned transaction's txid in display order.
        public let txid: String
        public let byInput: [Int: Data]

        public init(txid: String, byInput: [Int: Data]) {
            self.txid = txid
            self.byInput = byInput
        }

        public var text: String {
            ([Self.header + " " + txid] + byInput.keys.sorted().map { "\($0) \(byInput[$0]!.hex)" })
                .joined(separator: "\n")
        }

        public init(text: String) throws {
            let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard let first = lines.first, first.hasPrefix(Self.header + " ") else {
                throw SatochipError.malformedResponse("not a Winnow Satochip approval")
            }
            let txid = String(first.dropFirst(Self.header.count + 1))
            guard txid.count == 64, Data(hex: txid) != nil else { throw SatochipError.malformedResponse("approval txid") }
            var byInput: [Int: Data] = [:]
            for line in lines.dropFirst() {
                let fields = line.split(separator: " ")
                guard fields.count == 2, let input = Int(fields[0]), input >= 0, byInput[input] == nil,
                      let approval = Data(hex: String(fields[1])), approval.count == 22,
                      approval.prefix(2) == Satochip.twoFactorFlag
                else { throw SatochipError.malformedResponse("approval line") }
                byInput[input] = approval
            }
            guard !byInput.isEmpty else { throw SatochipError.malformedResponse("no approvals") }
            self.init(txid: txid, byInput: byInput)
        }
    }
}
