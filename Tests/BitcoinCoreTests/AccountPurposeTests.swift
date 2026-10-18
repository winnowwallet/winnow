import Foundation
import Testing
import TestSupport
@testable import WalletCore

@Suite("Account purposes")
struct AccountPurposeTests {
    @Test("the account path is m/purpose'/coin'/account'")
    func paths() throws {
        let hardened = HDKey.hardenedOffset
        #expect(try AccountPurpose.bip44.accountPath(coinType: 0, account: 0) == [44 + hardened, hardened, hardened])
        #expect(try AccountPurpose.bip49.accountPath(coinType: 1, account: 2) == [49 + hardened, 1 + hardened, 2 + hardened])
        #expect(try AccountPurpose.bip84.accountPath(coinType: 0, account: 2_147_483_646)
            == [84 + hardened, hardened, 2_147_483_646 + hardened])
        #expect(throws: BIP32Error.invalidPath) { try AccountPurpose.bip84.accountPath(coinType: 0, account: hardened) }
        #expect(throws: BIP32Error.invalidPath) { try AccountPurpose.bip84.accountPath(coinType: hardened, account: 0) }
    }

    @Test("the BIP86 purpose derives the account BIP86 derives")
    func bip86Agrees() throws {
        let master = try testMaster()
        #expect(try AccountPurpose.bip86.accountKey(from: master, coinType: 1, account: 3)
            == BIP86.accountKey(from: master, coinType: 1, account: 3))
        #expect(try AccountPurpose.bip44.accountKey(from: master) == master.derived(path: "m/44'/0'/0'"))
    }

    @Test("each purpose names its SLIP-0132 row; BIP86 stays on xpub")
    func versions() {
        #expect(AccountPurpose.bip44.extendedKeyVersion(network: .mainnet) == .xpub)
        #expect(AccountPurpose.bip49.extendedKeyVersion(network: .mainnet) == .ypub)
        #expect(AccountPurpose.bip84.extendedKeyVersion(network: .mainnet) == .zpub)
        #expect(AccountPurpose.bip86.extendedKeyVersion(network: .mainnet) == .xpub)
        #expect(AccountPurpose.bip44.extendedKeyVersion(network: .testnet) == .tpub)
        #expect(AccountPurpose.bip49.extendedKeyVersion(network: .testnet) == .upub)
        #expect(AccountPurpose.bip84.extendedKeyVersion(network: .testnet) == .vpub)
        #expect(AccountPurpose.bip86.extendedKeyVersion(network: .testnet) == .tpub)
        #expect(AccountPurpose.allCases.map(\.rawValue) == [44, 49, 84, 86])
    }
}
