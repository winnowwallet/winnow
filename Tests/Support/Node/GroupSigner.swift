import Foundation
import P256K
import WalletCore

/// A software group signer shared by Core comparisons and the group-vault UI journey.
public enum GroupSigner {
    private enum SigningError: Error { case missingLeaf, missingDerivation, invalidPartialSignature }

    /// Adds the group's script-path signature, applying the BIP328 path in the PSBT.
    public static func sign(_ unsigned: PSBT, memberSecrets: [Data], synthetic: HDKey) throws -> PSBT {
        var psbt = unsigned
        let memberKeys = try memberSecrets.map {
            try P256K.Signing.PrivateKey(dataRepresentation: $0).publicKey.dataRepresentation
        }
        let aggregate = try MuSig.aggregate(memberKeys)
        guard let leaf = psbt.inputs[0].tapLeafScripts.first else {
            throw SigningError.missingLeaf
        }
        guard let derivation = psbt.inputs[0].tapBIP32Derivation.first(where: {
            $0.value.masterFingerprint == synthetic.fingerprint
        }) else { throw SigningError.missingDerivation }
        var tweaks: [Data] = []
        var step = synthetic
        for component in derivation.value.path {
            tweaks.append(MuSig.bip328Tweak(chainCode: step.chainCode,
                                            aggregatePublicKey: step.publicKey,
                                            index: component))
            step = try step.derived(path: "\(component)")
        }
        let sighash = try SighashBIP341.sighash(
            tx: try psbt.unsignedTransaction(), inputIndex: 0,
            spentOutputs: try psbt.spentOutputs(), hashType: .default,
            scriptPath: .init(leafScript: Script(leaf.script), leafVersion: leaf.leafVersion))
        var nonces: [(secret: Data, public_: Data)] = []
        for (secret, publicKey) in zip(memberSecrets, memberKeys) {
            let nonce = try MuSig.nonceGenerate(secretKey: secret, publicKey: publicKey,
                                                aggregateKey: Data(aggregate.dropFirst()),
                                                message: sighash)
            nonces.append((nonce.secretNonce, nonce.publicNonce))
        }
        let session = MuSig.Session(
            aggregateNonce: try MuSig.nonceAggregate(publicNonces: nonces.map(\.public_)),
            publicKeys: memberKeys, tweaks: tweaks,
            isXOnlyTweaks: tweaks.map { _ in false }, message: sighash)
        var partials: [Data] = []
        for (index, secret) in memberSecrets.enumerated() {
            var secretNonce = nonces[index].secret
            let partial = try MuSig.partialSign(secretNonce: &secretNonce, secretKey: secret, session: session)
            guard try MuSig.partialVerify(partialSignature: partial, publicNonce: nonces[index].public_,
                                          publicKey: memberKeys[index], session: session) else {
                throw SigningError.invalidPartialSignature
            }
            partials.append(partial)
        }
        let signature = try MuSig.partialSigAggregate(partialSignatures: partials, session: session)
        psbt.inputs[0].pairs.append(PSBT.KeyValue(
            type: 0x14, keyData: Data(derivation.key) + leaf.leafHash, value: signature))
        return psbt
    }

}
