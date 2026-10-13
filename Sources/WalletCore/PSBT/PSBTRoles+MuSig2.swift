import Foundation
import P256K

// The MuSig2 (vault) PSBT roles live beside MuSig2 itself; the
// single-signer roles are in WinnowPrimitives.
extension PSBT {
    // MARK: - MuSig2 (vault) roles — BIP373 transport

    /// Creator-side helper: attaches PSBT_IN_TAP_INTERNAL_KEY (the BIP328-
    /// derived, pre-TapTweak aggregate key) and PSBT_IN_MUSIG2_PARTICIPANT_PUBKEYS
    /// for a MuSig2 vault input (BIP373). `participants` are the sorted
    /// compressed keys the session aggregates over.
    public mutating func attachMuSig2(input index: Int, internalKey: Data, aggregate: Data,
                                      participants: [Data]) throws {
        guard inputs.indices.contains(index) else { throw PSBTError.missingField("input \(index)") }
        guard internalKey.count == 32, aggregate.count == 33, !participants.isEmpty else {
            throw PSBTError.malformed("musig2 keys")
        }
        inputs[index].tapInternalKey = internalKey
        var all = inputs[index].musig2ParticipantPubKeys
        all[aggregate] = participants
        inputs[index].musig2ParticipantPubKeys = all
    }

    /// Round 1 (BIP373): attaches the caller's 66-byte public nonce.
    public mutating func attachMuSig2PubNonce(input index: Int, id: MuSig2KeyID, nonce: Data) throws {
        guard inputs.indices.contains(index) else { throw PSBTError.missingField("input \(index)") }
        guard nonce.count == 66 else { throw PSBTError.malformed("pubnonce length \(nonce.count)") }
        var nonces = inputs[index].musig2PubNonces
        nonces[id] = nonce
        inputs[index].musig2PubNonces = nonces
    }

    /// Builds the BIP327 session from the PSBT contents once every
    /// participant has attached a nonce: the aggregate nonce is the BIP327
    /// NonceAgg of the nonces in participant order. `message` is the BIP341
    /// key-path sighash; the tweak chain comes from the vault descriptor
    /// (BIP328 path tweaks, then the x-only TapTweak).
    public func muSig2Session(input index: Int, aggregateKey: Data, tweaks: [Data],
                              isXOnlyTweaks: [Bool], message: Data) throws -> MuSig.Session {
        guard inputs.indices.contains(index) else { throw PSBTError.missingField("input \(index)") }
        guard let participants = inputs[index].musig2ParticipantPubKeys[aggregateKey] else {
            throw PSBTError.missingField("input \(index) musig2 participants")
        }
        let nonces = inputs[index].musig2PubNonces
        // Participant lists name the root aggregate; signing contributions
        // name the actual output key, after derivation and TapTweak (BIP373).
        let signingKey = try MuSig.aggregate(publicKeys: participants, tweaks: tweaks,
                                             isXOnlyTweaks: isXOnlyTweaks)
        var ordered: [Data] = []
        for participant in participants {
            guard let nonce = nonces[MuSig2KeyID(participant: participant, aggregate: signingKey)] else {
                throw PSBTError.missingField("input \(index) musig2 nonce for \(participant.hex)")
            }
            ordered.append(nonce)
        }
        return MuSig.Session(aggregateNonce: try MuSig.nonceAggregate(publicNonces: ordered),
                             publicKeys: participants, tweaks: tweaks,
                             isXOnlyTweaks: isXOnlyTweaks, message: message)
    }

    /// Round 2 (BIP373/BIP327): produces the caller's partial signature and
    /// attaches it after a successful partial self-verification. The secret
    /// nonce is zeroed by `MuSig.partialSign`.
    public mutating func signMuSig2(input index: Int, id: MuSig2KeyID, secretNonce: inout Data,
                                    secretKey: Data, session: MuSig.Session) throws {
        guard inputs.indices.contains(index) else { throw PSBTError.missingField("input \(index)") }
        let nonces = inputs[index].musig2PubNonces
        guard let ownNonce = nonces[id] else {
            throw PSBTError.missingField("input \(index) own musig2 nonce")
        }
        let partial = try MuSig.partialSign(secretNonce: &secretNonce, secretKey: secretKey, session: session)
        guard try MuSig.partialVerify(partialSignature: partial, publicNonce: ownNonce,
                                      publicKey: id.participant, session: session) else {
            throw PSBTError.malformed("self-produced partial signature failed verification")
        }
        var partials = inputs[index].musig2PartialSigs
        partials[id] = partial
        inputs[index].musig2PartialSigs = partials
    }

    /// Aggregation (BIP327 PartialSigAgg): verifies every partial, combines
    /// them into the 64-byte BIP340 signature over the tweaked aggregate key
    /// and stores it as PSBT_IN_TAP_KEY_SIG, ready for `finalize()`.
    public mutating func aggregateMuSig2(input index: Int, session: MuSig.Session) throws {
        guard inputs.indices.contains(index) else { throw PSBTError.missingField("input \(index)") }
        let partials = inputs[index].musig2PartialSigs
        let nonces = inputs[index].musig2PubNonces
        let aggregate = try MuSig.aggregate(publicKeys: session.publicKeys, tweaks: session.tweaks,
                                            isXOnlyTweaks: session.isXOnlyTweaks)
        var ordered: [Data] = []
        for participant in session.publicKeys {
            let id = MuSig2KeyID(participant: participant, aggregate: aggregate)
            guard let partial = partials[id], let nonce = nonces[id] else {
                throw PSBTError.missingField("input \(index) musig2 partial sig for \(participant.hex)")
            }
            // Reject a wrong-key or otherwise invalid partial before combining.
            guard try MuSig.partialVerify(partialSignature: partial, publicNonce: nonce,
                                          publicKey: participant, session: session) else {
                throw PSBTError.malformed("invalid partial signature from \(participant.hex)")
            }
            ordered.append(partial)
        }
        let signature = try MuSig.partialSigAggregate(partialSignatures: ordered, session: session)
        // The aggregate must be a valid BIP340 signature for the tweaked
        // aggregate key over the session message (the key-path sighash).
        let aggregateXonly = try MuSig.aggregateXonly(publicKeys: session.publicKeys,
                                                      tweaks: session.tweaks,
                                                      isXOnlyTweaks: session.isXOnlyTweaks)
        var message = [UInt8](session.message)
        let parsed = try P256K.Schnorr.SchnorrSignature(dataRepresentation: signature)
        guard P256K.Schnorr.XonlyKey(dataRepresentation: aggregateXonly).isValid(parsed, for: &message) else {
            throw PSBTError.malformed("aggregate signature failed verification")
        }
        // BIP341: a 64-byte witness signature means SIGHASH_DEFAULT; a non-default
        // type (only ALL survives keyPathSighash's guard) must append its byte,
        // or the finalized witness is consensus-invalid. Mirrors Signer.witness.
        let hashType = SighashBIP341.HashType(rawValue: UInt8(truncatingIfNeeded: inputs[index].sighashType ?? 0))
        inputs[index].tapKeySignature = hashType == .default ? signature : signature + Data([hashType.rawValue])
    }
}
