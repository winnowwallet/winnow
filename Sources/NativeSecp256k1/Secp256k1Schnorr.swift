import Foundation

extension Secp256k1 {
    /// BIP340 Schnorr signatures, following the specification's reference
    /// algorithm step for step so that signatures are byte-identical to
    /// libsecp256k1's for the same key, message and auxiliary randomness.
    public enum Schnorr {
        /// Signs `message` (any length; Winnow passes a 32-byte sighash) and
        /// returns the 64-byte signature r ‖ s. `auxiliaryRand` must be exactly
        /// 32 bytes; it de-randomises the nonce derivation only, so a repeated
        /// value is safe but gives up the defence against fault attacks.
        /// The fresh signature is verified before it is returned.
        public static func sign(message: Data, privateKey: PrivateKey, auxiliaryRand: Data) throws -> Data {
            guard auxiliaryRand.count == 32 else { throw Secp256k1Error.invalidAuxiliaryRand }
            let point = privateKey.publicKey.point
            let d = point.hasOddY ? privateKey.scalar.negated() : privateKey.scalar
            let publicX = point.x.bigEndian

            let mask = TaggedSHA256.hash(tag: "BIP0340/aux", message: auxiliaryRand)
            let masked = Data(zip(d.bigEndian, mask).map(^))
            let rand = TaggedSHA256.hash(tag: "BIP0340/nonce", message: masked + publicX + message)
            let nonce = Scalar(reducingHash: rand)
            guard !nonce.isZero, let r = Curve.multiplyGenerator(nonce).affine() else {
                throw Secp256k1Error.signingFailed
            }
            let k = r.hasOddY ? nonce.negated() : nonce
            let rX = r.x.bigEndian

            let e = challenge(rX: rX, publicX: publicX, message: message)
            let s = k + e.multiplied(by: d)
            let signature = rX + s.bigEndian
            guard verify(signature: signature, message: message, publicKey: publicX) else {
                throw Secp256k1Error.signingFailed
            }
            return signature
        }

        /// BIP340 verification of a 64-byte signature under a 32-byte x-only
        /// key. Never throws: every malformed input is simply invalid.
        public static func verify(signature: Data, message: Data, publicKey x: Data) -> Bool {
            guard signature.count == 64, let key = try? XOnlyKey(x) else { return false }
            let bytes = Array(signature)
            guard let r = FieldElement(bigEndian: Data(bytes[0 ..< 32])),
                  let s = Scalar(bigEndian: Data(bytes[32 ..< 64]))
            else { return false }
            let e = challenge(rX: r.bigEndian, publicX: key.x, message: message)
            // R = s·G − e·P, with e·P brought to affine form for the mixed addition.
            var sum = Curve.multiplyGenerator(s)
            if let eP = Curve.multiply(key.point, by: e).affine() {
                sum = sum.adding(eP.negated)
            }
            guard let result = sum.affine() else { return false }
            return !result.hasOddY && result.x == r
        }

        /// e = int(hash_challenge(r ‖ P ‖ m)) mod n.
        static func challenge(rX: Data, publicX: Data, message: Data) -> Scalar {
            Scalar(reducingHash: TaggedSHA256.hash(tag: "BIP0340/challenge", message: rX + publicX + message))
        }
    }
}

extension Scalar {
    /// A 32-byte hash output taken as a big-endian integer modulo n.
    init(reducingHash hash: Data) {
        self.init(reducing: Integer256(bigEndian: hash) ?? .zero)
    }
}
