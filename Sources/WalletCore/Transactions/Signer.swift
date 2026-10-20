import Foundation
import NativeSecp256k1

public enum SignerError: Error, Equatable {
    case invalidPrivateKey
    /// Auxiliary randomness that is not exactly 32 bytes.
    case invalidAuxiliaryRand
    case spentOutputCountMismatch(inputs: Int, spentOutputs: Int)
    /// No key resolved for an input's spent scriptPubKey (hex).
    case missingKey(scriptPubKey: String)
}

/// Single-sig Taproot key-path signer (BIP341/BIP340): the tweaked private key
/// (BIP86 — internal key tweaked with NO merkle root, see BitcoinCore's
/// `BIP86.tweakedPrivateKey`), a Schnorr signature over the BIP341 sighash, and
/// a witness of a single stack item (the 64-byte signature; 65 bytes with the
/// sighash byte appended for non-default hash types).
public enum Signer {
    /// Produces the witness stack for one input. `tweakedPrivateKey` is the
    /// BIP86 tweaked secret for the input's output key.
    public static func witness(tx: Transaction, inputIndex: Int,
                               spentOutputs: [SighashBIP341.SpentOutput],
                               tweakedPrivateKey: Data,
                               hashType: SighashBIP341.HashType = .default,
                               auxiliaryRand: Data? = nil) throws -> [Data] {
        let sighash = try SighashBIP341.sighash(tx: tx, inputIndex: inputIndex,
                                                spentOutputs: spentOutputs, hashType: hashType)
        guard let key = try? Secp256k1.PrivateKey(tweakedPrivateKey) else {
            throw SignerError.invalidPrivateKey
        }
        let aux = auxiliaryRand ?? randomAuxiliaryRand()
        guard aux.count == 32 else { throw SignerError.invalidAuxiliaryRand }
        var item = try Secp256k1.Schnorr.sign(message: sighash, privateKey: key, auxiliaryRand: aux)
        // BIP341: a 64-byte sig implies SIGHASH_DEFAULT; other types append the byte.
        if hashType != .default { item.append(hashType.rawValue) }
        return [item]
    }

    /// Signs every input in place (witness = single signature item).
    /// `privateKeyFor` resolves the BIP86 tweaked private key from the spent
    /// scriptPubKey; returning nil throws `missingKey`.
    public static func sign(tx: inout Transaction, spentOutputs: [SighashBIP341.SpentOutput],
                            hashType: SighashBIP341.HashType = .default,
                            auxiliaryRand: Data? = nil,
                            privateKeyFor: (Data) throws -> Data?) throws {
        guard tx.inputs.count == spentOutputs.count else {
            throw SignerError.spentOutputCountMismatch(
                inputs: tx.inputs.count, spentOutputs: spentOutputs.count)
        }
        for index in tx.inputs.indices {
            guard let privateKey = try privateKeyFor(spentOutputs[index].scriptPubKey) else {
                throw SignerError.missingKey(scriptPubKey: spentOutputs[index].scriptPubKey.hex)
            }
            tx.inputs[index].witness = try witness(tx: tx, inputIndex: index, spentOutputs: spentOutputs,
                                                   tweakedPrivateKey: privateKey, hashType: hashType,
                                                   auxiliaryRand: auxiliaryRand)
        }
    }

    /// Fresh 32-byte auxiliary randomness for BIP340 nonce derivation.
    static func randomAuxiliaryRand() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0 ..< 32).map { _ in UInt8.random(in: 0 ... 255, using: &generator) })
    }
}
