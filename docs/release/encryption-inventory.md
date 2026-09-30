# Winnow encryption inventory

This inventory lists the cryptography in the Winnow app (`com.btcswift.app`) so
the account holder can answer App Store Connect's export compliance questions.
It is not an exemption determination or an approved declaration. Record the
answers in [encryption-questionnaire.json](encryption-questionnaire.json) and
set `approved` only after that review. Release builds carry the answer
(`scripts/encryption-declaration-key`), and `scripts/encryption-declaration`
submits it for a processed build.

## Components in the app

| Use | Algorithms and implementation | Source |
| --- | --- | --- |
| Lightning peer transport (BOLT 8) | Noise XK: secp256k1 ECDH through P256K/libsecp256k1; SHA-256, HKDF-SHA256 and ChaCha20-Poly1305 through Apple CryptoKit. 256-bit traffic keys. | [NoiseCrypto.swift](../../Sources/LightningCore/NoiseCrypto.swift), [LightningHandshake.swift](../../Sources/LightningCore/LightningHandshake.swift), [LightningTransport.swift](../../Sources/LightningCore/LightningTransport.swift) |
| Payment and message onions (BOLT 4) | Sphinx packets: secp256k1 ECDH, HMAC-SHA256, and a 256-bit ChaCha20 stream implemented in Swift (`OnionStream`), not supplied by CryptoKit. | [OnionPacket.swift](../../Sources/LightningCore/OnionPacket.swift), [OnionMessage.swift](../../Sources/LightningCore/OnionMessage.swift), [BlindedPayment.swift](../../Sources/LightningCore/BlindedPayment.swift) |
| Channel records on the device | AES-GCM through CryptoKit with 256-bit keys held in the Keychain (this device only). The full journal also uses complete file protection; the recovery journal holds no seed, node key or revocation secret. | [LightningJournal.swift](../../Sources/LightningCore/LightningJournal.swift) |
| Lightning recovery file | The wallet bundle and channel recovery keys, encrypted with a separate 24-word phrase using the same code as the iCloud backup. | [PortableLightningBackup.swift](../../Sources/WinnowLightningApp/PortableLightningBackup.swift) |
| iCloud wallet backup | AES-GCM through CryptoKit; the key is synchronized through iCloud Keychain. | [CloudWalletBackup.swift](../../Sources/WalletCore/Wallet/CloudWalletBackup.swift) |
| Sealed local stores | HMAC-SHA256 authentication of local files, with Keychain keys. | [StoreAuthentication.swift](../../Sources/WinnowApp/StoreAuthentication.swift) |
| Signatures and keys | secp256k1 ECDSA and Schnorr through P256K/libsecp256k1; BIP32/BIP39/BIP86 derivation; SHA-256 and RIPEMD-160 hashing. | [WalletCore](../../Sources/WalletCore), [ChannelKeys.swift](../../Sources/LightningCore/ChannelKeys.swift) |

The only third-party Swift package is `swift-secp256k1` 0.23.2 (P256K, the C
libsecp256k1), pinned in [Package.resolved](../../Package.resolved). Core
Lightning, LDK and Bitcoin Core are host test peers in CI, never linked into
the app.

## What remains for the reviewer

Apple distinguishes encryption supplied only by the operating system from
standard algorithms implemented outside it, and requires a French declaration
when an app with such encryption is on the French App Store
([Apple's documentation table](https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption)).
Winnow is distributed through TestFlight and the App Store, so the answers
depend on its territories, which are set in App Store Connect and not recorded
here. The reviewer decides the classification and reporting basis for the
responsible entity; nothing in this repository makes that determination.
