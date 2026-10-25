import Foundation
import Testing
import TestSupport
@testable import WalletCore

/// HPKE against its published vectors: RFC 9180's X25519 cases drive the key
/// schedule, the AEADs, the nonce counter and the exporter; the secp256k1
/// KEM draft's cases drive the curve BIP 77 actually uses.
@Suite("HPKE (RFC 9180)")
struct HPKETests {
    // MARK: RFC 9180 vectors (DHKEM(X25519, HKDF-SHA256), HKDF-SHA256)

    private struct Vector: Decodable {
        struct Encryption: Decodable { let aad, ct, nonce, pt: String }
        struct Export: Decodable {
            let exporter_context, exported_value: String
            let L: Int
        }
        let mode: Int
        let kem_id, kdf_id, aead_id: Int
        let info, ikmE, ikmR, skEm, skRm, pkEm, pkRm, enc: String
        let ikmS, skSm, pkSm, psk, psk_id: String?
        let shared_secret, key, base_nonce, exporter_secret: String
        let encryptions: [Encryption]
        let exports: [Export]
    }

    private static func vectors() throws -> [Vector] {
        try Vectors.decode([Vector].self, "rfc9180-x25519-vectors.json", in: .module)
    }

    private func check<Cipher: HPKE.AEAD>(_ vector: Vector, _: Cipher.Type) throws {
        typealias Curve = HPKE.X25519
        typealias Suite = HPKE.Suite<Curve, Cipher>
        let hex = { (string: String) in Data(hex: string) ?? Data() }
        let skE = try HPKE.DHKEM<Curve>.deriveKeyPair(ikm: hex(vector.ikmE))
        let skR = try HPKE.DHKEM<Curve>.deriveKeyPair(ikm: hex(vector.ikmR))
        #expect(skE.rawRepresentation.hex == vector.skEm)
        #expect(Curve.serialize(skE.publicKey).hex == vector.pkEm)
        #expect(skR.rawRepresentation.hex == vector.skRm)
        let psk = hex(vector.psk ?? "")
        let pskID = hex(vector.psk_id ?? "")
        let pkR = try Curve.deserialize(hex(vector.pkRm))

        var sender: HPKE.Context<Cipher>
        var recipient: HPKE.Context<Cipher>
        let enc: Data
        if vector.mode == 2 || vector.mode == 3 {
            let skS = try HPKE.DHKEM<Curve>.deriveKeyPair(ikm: hex(try #require(vector.ikmS)))
            #expect(skS.rawRepresentation.hex == vector.skSm)
            (enc, sender) = try Suite.setupAuthSender(recipient: pkR, sender: skS, info: hex(vector.info),
                                                      psk: psk, pskID: pskID, ephemeral: skE)
            recipient = try Suite.setupAuthRecipient(enc: enc, recipient: skR, sender: skS.publicKey,
                                                     info: hex(vector.info), psk: psk, pskID: pskID)
        } else {
            (enc, sender) = try Suite.setupSender(recipient: pkR, info: hex(vector.info),
                                                  psk: psk, pskID: pskID, ephemeral: skE)
            recipient = try Suite.setupRecipient(enc: enc, recipient: skR, info: hex(vector.info),
                                                 psk: psk, pskID: pskID)
        }
        #expect(enc.hex == vector.enc)
        #expect(sender.key.hex == vector.key)
        #expect(sender.baseNonce.hex == vector.base_nonce)
        #expect(sender.exporterSecret.hex == vector.exporter_secret)
        #expect(recipient.key == sender.key)
        for (index, encryption) in vector.encryptions.enumerated() {
            let ciphertext = try sender.seal(aad: hex(encryption.aad), plaintext: hex(encryption.pt))
            #expect(ciphertext.hex == encryption.ct, "encryption \(index) of mode \(vector.mode)")
            let plaintext = try recipient.open(aad: hex(encryption.aad), ciphertext: ciphertext)
            #expect(plaintext.hex == encryption.pt)
        }
        for export in vector.exports {
            #expect(sender.export(context: hex(export.exporter_context), length: export.L).hex
                == export.exported_value)
        }
    }

    @Test("every vendored RFC 9180 vector: setup, encryptions and exports")
    func rfcVectors() throws {
        let vectors = try Self.vectors()
        #expect(vectors.count == 8, "four modes × two AEADs")
        for vector in vectors {
            #expect(vector.kem_id == 0x20 && vector.kdf_id == 1)
            switch vector.aead_id {
            case 1: try check(vector, HPKE.AESGCM128AEAD.self)
            case 3: try check(vector, HPKE.ChaChaPolyAEAD.self)
            default: Issue.record("unexpected AEAD \(vector.aead_id)")
            }
        }
    }

    // MARK: secp256k1 KEM draft vectors

    private struct DraftCase {
        var aead: Int
        var auth: Bool
        var fields: [String: String]
    }

    /// Appendix B of the draft: `key: value` lines, values wrapped onto
    /// continuation lines, grouped by the B.x (AEAD) and B.x.y (mode) heads.
    private static func draftCases() throws -> [DraftCase] {
        let text = try Vectors.string("draft-wahby-cfrg-hpke-kem-secp256k1-01.txt", in: .module)
        guard let appendix = text.range(of: "Appendix B.  Test Vectors", options: .backwards) else { throw VectorError.malformed("appendix") }
        var cases: [DraftCase] = []
        var aead = 0
        var auth = false
        var fields: [String: String] = [:]
        var lastKey: String?
        func flush() {
            if !fields.isEmpty { cases.append(DraftCase(aead: aead, auth: auth, fields: fields)) }
            fields = [:]
            lastKey = nil
        }
        for rawLine in text[appendix.upperBound...].split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("B.1.") || line.hasPrefix("B.2.") || line.hasPrefix("B.3.") {
                flush()
                aead = Int(String(line[line.index(line.startIndex, offsetBy: 2)])) ?? 0
                auth = line.hasSuffix("Auth")
            } else if line.hasPrefix("B.") && line.contains("DHKEM") {
                flush()
            } else if line.isEmpty || line.hasPrefix("Wabhy") || line.hasPrefix("Internet-Draft") {
                if line.isEmpty { flush() }
            } else if let colon = line.firstIndex(of: ":"), !line.contains(" ") || line.distance(from: line.startIndex, to: colon) < 20 {
                let key = String(line[..<colon])
                fields[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                lastKey = key
            } else if let lastKey {
                fields[lastKey, default: ""] += line
            }
            if line.hasPrefix("Author") { break }
        }
        flush()
        return cases
    }

    private func checkDraft<Cipher: HPKE.AEAD>(_ draft: DraftCase, _: Cipher.Type) throws {
        typealias Curve = HPKE.Secp256k1
        typealias Suite = HPKE.Suite<Curve, Cipher>
        let field = { (name: String) throws -> Data in
            guard let text = draft.fields[name], let bytes = Data(hex: text) else {
                throw VectorError.malformed("field \(name)")
            }
            return bytes
        }
        let skE = try HPKE.DHKEM<Curve>.deriveKeyPair(ikm: field("ikmE"))
        let skR = try HPKE.DHKEM<Curve>.deriveKeyPair(ikm: field("ikmR"))
        #expect(skE.rawRepresentation == (try field("skEm")))
        #expect(Curve.serialize(skE.publicKey) == (try field("pkEm")))
        #expect(skR.rawRepresentation == (try field("skRm")))
        #expect(Curve.serialize(skR.publicKey) == (try field("pkRm")))
        let info = try field("info")
        let (enc, context): (Data, HPKE.Context<Cipher>)
        if draft.auth {
            // The draft's Auth cases print the recipient's key pair under
            // skSm/pkSm, but their outputs were computed with the sender key
            // DeriveKeyPair gives for ikmS — so that is the key used here.
            let skS = try HPKE.DHKEM<Curve>.deriveKeyPair(ikm: field("ikmS"))
            #expect(try field("skSm") == (try field("skRm")), "the draft's quirk this test works around")
            (enc, context) = try Suite.setupAuthSender(recipient: skR.publicKey, sender: skS, info: info, ephemeral: skE)
            let (shared, _) = try HPKE.DHKEM<Curve>.encap(to: skR.publicKey, sender: skS, ephemeral: skE)
            #expect(shared == (try field("shared_secret")))
            let other = try Suite.setupAuthRecipient(enc: enc, recipient: skR, sender: skS.publicKey, info: info)
            #expect(other.key == context.key)
        } else {
            (enc, context) = try Suite.setupSender(recipient: skR.publicKey, info: info, ephemeral: skE)
            let (shared, _) = try HPKE.DHKEM<Curve>.encap(to: skR.publicKey, ephemeral: skE)
            #expect(shared == (try field("shared_secret")))
            let other = try Suite.setupRecipient(enc: enc, recipient: skR, info: info)
            #expect(other.key == context.key)
        }
        #expect(enc == (try field("pkEm")))
        #expect(context.key == (try field("key")))
        #expect(context.baseNonce == (try field("base_nonce")))
        #expect(context.exporterSecret == (try field("exporter_secret")))
    }

    @Test("draft-wahby secp256k1 KEM vectors: DeriveKeyPair, Base and Auth setups")
    func secp256k1DraftVectors() throws {
        let cases = try Self.draftCases()
        #expect(cases.count == 18, "three AEADs × (three Base + three Auth)")
        for draft in cases {
            switch draft.aead {
            case 1: try checkDraft(draft, HPKE.AESGCM128AEAD.self)
            case 2: try checkDraft(draft, HPKE.AESGCM256AEAD.self)
            case 3: try checkDraft(draft, HPKE.ChaChaPolyAEAD.self)
            default: Issue.record("unexpected section \(draft.aead)")
            }
        }
    }

    // MARK: Behaviour

    @Test("secp256k1 + ChaCha20-Poly1305 round trips in Base and Auth mode, and refuses the wrong keys")
    func secp256k1RoundTrips() throws {
        typealias Suite = HPKE.Suite<HPKE.Secp256k1, HPKE.ChaChaPolyAEAD>
        let skR = try HPKE.Secp256k1.generatePrivateKey()
        let skS = try HPKE.Secp256k1.generatePrivateKey()
        let info = Data("PjV2MsgB".utf8)
        var (enc, sender) = try Suite.setupAuthSender(recipient: skR.publicKey, sender: skS, info: info)
        let first = try sender.seal(plaintext: Data("one".utf8))
        let second = try sender.seal(aad: Data("aad".utf8), plaintext: Data("two".utf8))
        var recipient = try Suite.setupAuthRecipient(enc: enc, recipient: skR, sender: skS.publicKey, info: info)
        #expect(try recipient.open(ciphertext: first) == Data("one".utf8))
        #expect(try recipient.open(aad: Data("aad".utf8), ciphertext: second) == Data("two".utf8))
        #expect(sender.export(context: Data("x".utf8), length: 32) == recipient.export(context: Data("x".utf8), length: 32))

        // Another sender key does not authenticate.
        var impostor = try Suite.setupAuthRecipient(enc: enc, recipient: skR,
                                                    sender: try HPKE.Secp256k1.generatePrivateKey().publicKey, info: info)
        #expect(throws: HPKE.Failure.openFailed) { try impostor.open(ciphertext: first) }
        // Base mode with a different info string does not open either.
        (enc, sender) = try Suite.setupSender(recipient: skR.publicKey, info: info)
        let sealed = try sender.seal(plaintext: Data("base".utf8))
        var wrongInfo = try Suite.setupRecipient(enc: enc, recipient: skR, info: Data("PjV2MsgA".utf8))
        #expect(throws: HPKE.Failure.openFailed) { try wrongInfo.open(ciphertext: sealed) }
        var tampered = sealed
        tampered[tampered.startIndex] ^= 1
        var right = try Suite.setupRecipient(enc: enc, recipient: skR, info: info)
        #expect(throws: HPKE.Failure.openFailed) { try right.open(ciphertext: tampered) }
        #expect(throws: HPKE.Failure.invalidLength) {
            try Suite.setupRecipient(enc: enc.dropLast(), recipient: skR, info: info)
        }
    }

    @Test("a PSK is required exactly in the PSK modes")
    func pskModes() throws {
        typealias Suite = HPKE.Suite<HPKE.X25519, HPKE.ChaChaPolyAEAD>
        #expect(throws: HPKE.Failure.missingPSK) {
            try Suite.keySchedule(mode: .psk, sharedSecret: Data(count: 32), info: Data())
        }
        #expect(throws: HPKE.Failure.missingPSK) {
            try Suite.keySchedule(mode: .base, sharedSecret: Data(count: 32), info: Data(), psk: Data([1]))
        }
    }
}
