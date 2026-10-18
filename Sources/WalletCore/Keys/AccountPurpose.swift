import Foundation

/// The BIP43 purpose of a single-key account. It fixes the account path and,
/// with it, the script the account's addresses pay to; the scripts themselves
/// are not derived here.
public enum AccountPurpose: UInt32, CaseIterable, Sendable {
    /// m/44'/coin'/account': P2PKH (BIP44).
    case bip44 = 44
    /// m/49'/coin'/account': P2WPKH nested in P2SH (BIP49).
    case bip49 = 49
    /// m/84'/coin'/account': P2WPKH (BIP84).
    case bip84 = 84
    /// m/86'/coin'/account': P2TR (BIP86), the account Winnow keeps itself.
    case bip86 = 86

    /// The hardened path m/purpose'/coinType'/account' as child indices.
    public func accountPath(coinType: UInt32, account: UInt32) throws -> [UInt32] {
        guard coinType < HDKey.hardenedOffset, account < HDKey.hardenedOffset else { throw BIP32Error.invalidPath }
        return [rawValue, coinType, account].map { $0 + HDKey.hardenedOffset }
    }

    /// The account-level extended key at m/purpose'/coinType'/account'.
    public func accountKey(from master: HDKey, coinType: UInt32 = 0, account: UInt32 = 0) throws -> HDKey {
        try master.derived(path: accountPath(coinType: coinType, account: account))
    }

    /// The SLIP-0132 script the purpose's account key is written under by
    /// wallets that use the registry. BIP86 keys stay xpub: the registry has
    /// no taproot row.
    public var extendedKeyScript: ExtendedKeyVersion.Script {
        switch self {
        case .bip44, .bip86: .legacy
        case .bip49: .nestedSegwit
        case .bip84: .nativeSegwit
        }
    }

    /// The SLIP-0132 row for this purpose on a network.
    public func extendedKeyVersion(network: HDKey.Network) -> ExtendedKeyVersion {
        ExtendedKeyVersion.version(for: extendedKeyScript, network: network)
    }
}
