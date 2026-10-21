import CryptoKit
import Foundation

/// A BIP388 wallet policy as Ledger's Bitcoin app registers it: a name, a
/// descriptor template over key placeholders, and the keys. The device keeps
/// nothing; registration returns an HMAC the phone stores and sends with
/// every later request for this account.
public struct LedgerWalletPolicy: Equatable, Sendable {
    public let name: String
    /// For example `tr(@0/**,sortedmulti_a(2,@1/**,@2/**))`.
    public let template: String
    /// Key information in placeholder order: `[fingerprint/path]xpub`, or a
    /// bare xpub for a key with no origin.
    public let keys: [String]

    /// Names are shown on the Ledger: 1 to 64 printable ASCII characters,
    /// with no space at either end.
    public static func isValidName(_ name: String) -> Bool {
        let bytes = Array(name.utf8)
        return (1 ... 64).contains(bytes.count) && bytes.allSatisfy { (0x20 ... 0x7E).contains($0) }
            && bytes.first != 0x20 && bytes.last != 0x20
    }

    public init(name: String, template: String, keys: [String]) throws {
        guard Self.isValidName(name) else {
            throw LedgerError.mismatch("an account name must be 1 to 64 plain characters with no space at either end")
        }
        guard !keys.isEmpty, keys.count <= 252 else { throw LedgerError.mismatch("a policy needs 1 to 252 keys") }
        self.name = name
        self.template = template
        self.keys = keys
    }

    /// The account's descriptor as a policy: the internal key is `@0`, the
    /// signers follow in descriptor order, and each key's `/<0;1>/*` becomes
    /// `/**`. The template therefore derives exactly the account's addresses.
    public init(name: String, account: MultisigAccount) throws {
        guard case let .trTree(internalKey, _) = account.descriptor.expression,
              case .extended = internalKey.base else {
            throw LedgerError.mismatch("only accounts whose internal key is an extended key can be registered")
        }
        let placeholders = (1 ... account.signers.count).map { "@\($0)/**" }.joined(separator: ",")
        let leaf = account.isSorted ? "sortedmulti_a" : "multi_a"
        let template = "tr(@0/**,\(leaf)(\(account.threshold),\(placeholders)))"
        let keys = try ([internalKey] + account.signers).map(Self.keyInformation)
        try self.init(name: name, template: template, keys: keys)
    }

    /// `[fingerprint/86'/1'/0']tpub…` with the derivation suffix removed.
    static func keyInformation(_ key: Descriptor.SingleKey) throws -> String {
        guard case let .extended(xpub, network) = key.base, xpub.privateKey == nil,
              key.derivation.elements == MultisigAccount.signerSuffix else {
            throw LedgerError.mismatch("every policy key must be an extended public key under /<0;1>/*")
        }
        var text = ""
        if let origin = key.origin {
            text += "[" + String(format: "%08x", origin.fingerprint)
            for step in origin.path {
                text += "/\(step & ~HDKey.hardenedOffset)" + (step >= HDKey.hardenedOffset ? "'" : "")
            }
            text += "]"
        }
        return text + xpub.serialized(network: network)
    }

    /// Version 2: 0x02 ‖ name length ‖ name ‖ compactSize(template length) ‖
    /// SHA-256(template) ‖ compactSize(key count) ‖ Merkle root of the keys.
    public var serialized: Data {
        var data = Data([0x02, UInt8(name.utf8.count)])
        data += Data(name.utf8)
        data.appendCompactSize(UInt64(template.utf8.count))
        data += Data(SHA256.hash(data: Data(template.utf8)))
        data.appendCompactSize(UInt64(keys.count))
        data += LedgerMerkle.root(keys.map { LedgerMerkle.elementHash(Data($0.utf8)) })
        return data
    }

    /// The policy id the device returns on registration: SHA-256 of `serialized`.
    public var id: Data { Data(SHA256.hash(data: serialized)) }

    /// Everything the device may ask for while it works with this policy.
    func register(in interpreter: inout LedgerClientCommandInterpreter) {
        interpreter.addKnownList(keys.map { Data($0.utf8) })
        interpreter.addKnownPreimage(serialized)
        interpreter.addKnownPreimage(Data(template.utf8))
    }
}
