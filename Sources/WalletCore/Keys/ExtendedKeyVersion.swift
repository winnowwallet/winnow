import Foundation

/// The four version bytes in front of a serialized extended key. BIP32 names
/// xpub/xprv and tpub/tprv; SLIP-0132 registers one more pair per script
/// type, so an account key handed over by another wallet also says how its
/// addresses are formed (`ypub` for nested segwit, `zpub` for native). Winnow's
/// own keys stay xpub/xprv: these rows are read on import and written on
/// request, never a second serialization of wallet state.
public struct ExtendedKeyVersion: Sendable, Equatable, Hashable {
    /// What the registry says addresses under this key look like.
    public enum Script: Sendable, Equatable, Hashable {
        /// P2PKH or P2SH: the BIP32 bytes, which BIP44 and BIP86 wallets both use.
        case legacy
        /// P2WPKH nested in P2SH (BIP49).
        case nestedSegwit
        /// P2WPKH (BIP84).
        case nativeSegwit
        /// Multi-signature P2WSH nested in P2SH.
        case nestedSegwitMultisig
        /// Multi-signature P2WSH.
        case nativeSegwitMultisig
    }

    public let script: Script
    public let network: HDKey.Network
    public let publicPrefix: String
    public let privatePrefix: String
    public let publicBytes: UInt32
    public let privateBytes: UInt32

    public static let xpub = ExtendedKeyVersion(script: .legacy, network: .mainnet, publicPrefix: "xpub",
                                                privatePrefix: "xprv", publicBytes: 0x0488_B21E, privateBytes: 0x0488_ADE4)
    public static let ypub = ExtendedKeyVersion(script: .nestedSegwit, network: .mainnet, publicPrefix: "ypub",
                                                privatePrefix: "yprv", publicBytes: 0x049D_7CB2, privateBytes: 0x049D_7878)
    public static let zpub = ExtendedKeyVersion(script: .nativeSegwit, network: .mainnet, publicPrefix: "zpub",
                                                privatePrefix: "zprv", publicBytes: 0x04B2_4746, privateBytes: 0x04B2_430C)
    public static let capitalYpub = ExtendedKeyVersion(script: .nestedSegwitMultisig, network: .mainnet, publicPrefix: "Ypub",
                                                       privatePrefix: "Yprv", publicBytes: 0x0295_B43F, privateBytes: 0x0295_B005)
    public static let capitalZpub = ExtendedKeyVersion(script: .nativeSegwitMultisig, network: .mainnet, publicPrefix: "Zpub",
                                                       privatePrefix: "Zprv", publicBytes: 0x02AA_7ED3, privateBytes: 0x02AA_7A99)
    public static let tpub = ExtendedKeyVersion(script: .legacy, network: .testnet, publicPrefix: "tpub",
                                                privatePrefix: "tprv", publicBytes: 0x0435_87CF, privateBytes: 0x0435_8394)
    public static let upub = ExtendedKeyVersion(script: .nestedSegwit, network: .testnet, publicPrefix: "upub",
                                                privatePrefix: "uprv", publicBytes: 0x044A_5262, privateBytes: 0x044A_4E28)
    public static let vpub = ExtendedKeyVersion(script: .nativeSegwit, network: .testnet, publicPrefix: "vpub",
                                                privatePrefix: "vprv", publicBytes: 0x045F_1CF6, privateBytes: 0x045F_18BC)
    public static let capitalUpub = ExtendedKeyVersion(script: .nestedSegwitMultisig, network: .testnet, publicPrefix: "Upub",
                                                       privatePrefix: "Uprv", publicBytes: 0x0242_89EF, privateBytes: 0x0242_85B5)
    public static let capitalVpub = ExtendedKeyVersion(script: .nativeSegwitMultisig, network: .testnet, publicPrefix: "Vpub",
                                                       privatePrefix: "Vprv", publicBytes: 0x0257_5483, privateBytes: 0x0257_5048)

    /// The Bitcoin rows of SLIP-0132, mainnet then testnet, in the registry's
    /// order. Testnet's bytes also serve signet and regtest, as BIP32's do.
    public static let registry: [ExtendedKeyVersion] = [
        xpub, ypub, zpub, capitalYpub, capitalZpub, tpub, upub, vpub, capitalUpub, capitalVpub,
    ]

    /// The row whose public or private prefix is `prefix`. Case matters:
    /// `Zpub` is a multisig key and `zpub` a single-key one.
    public static func named(_ prefix: String) -> ExtendedKeyVersion? {
        registry.first { $0.publicPrefix == prefix || $0.privatePrefix == prefix }
    }

    /// The row carrying `bytes` as its public or private version.
    public static func matching(bytes: UInt32) -> ExtendedKeyVersion? {
        registry.first { $0.publicBytes == bytes || $0.privateBytes == bytes }
    }

    /// The row for a script type on a network.
    public static func version(for script: Script, network: HDKey.Network) -> ExtendedKeyVersion {
        switch (script, network) {
        case (.legacy, .mainnet): xpub
        case (.nestedSegwit, .mainnet): ypub
        case (.nativeSegwit, .mainnet): zpub
        case (.nestedSegwitMultisig, .mainnet): capitalYpub
        case (.nativeSegwitMultisig, .mainnet): capitalZpub
        case (.legacy, .testnet): tpub
        case (.nestedSegwit, .testnet): upub
        case (.nativeSegwit, .testnet): vpub
        case (.nestedSegwitMultisig, .testnet): capitalUpub
        case (.nativeSegwitMultisig, .testnet): capitalVpub
        }
    }

    /// The bytes a key of this privateness is written under.
    public func bytes(forPrivate isPrivate: Bool) -> UInt32 {
        isPrivate ? privateBytes : publicBytes
    }

    /// Parses an extended key written under any registered row, answering the
    /// key and the row. The key material and master-key invariants are checked
    /// as `HDKey.deserialize` checks them; only the version table is wider.
    public static func decode(_ string: String) throws -> (key: HDKey, version: ExtendedKeyVersion) {
        let (key, bytes) = try HDKey.deserialize(string, privateVersions: Set(registry.map(\.privateBytes)),
                                                 publicVersions: Set(registry.map(\.publicBytes)))
        guard let version = matching(bytes: bytes) else { throw BIP32Error.invalidVersion }
        return (key, version)
    }
}

extension HDKey {
    /// Base58Check serialization under a SLIP-0132 row: the row's private bytes
    /// for a private key, its public bytes for a neutered one.
    public func serialized(version: ExtendedKeyVersion) -> String {
        serialized(version: version.bytes(forPrivate: isPrivate))
    }
}
