import WalletCore
import Testing
import TestSupport

/// The Core fixture's descriptor parser is pure: no node or wallet is needed.
@Suite("Core signer descriptor parsing")
struct CoreSignerTests {
    @Test("Core fixture preserves base58 keys ending in h", arguments: ["h", "'"])
    func keyExpressionPreservesBase58(hardened: String) throws {
        let key = "tpubDDChux5N2nzqQBFzaBdidpdEGspdKEmRwi7gQdbqpnHvAviVZxikms3ZjaSQVLmnFaopeDnoBDdRdocHBBnw2K7AbiQLJLdnuQX1cbTPYFh"
        let input = "tr([e11008c1/86\(hardened)/1\(hardened)/0\(hardened)]\(key)/0/*)"
        let expression = try CoreSigner.keyExpression(from: input) + "/<0;1>/*"
        #expect(expression == "[e11008c1/86'/1'/0']\(key)/<0;1>/*")
        #expect(try Descriptor("tr(\(expression))").serialized().contains(expression))
    }
}
