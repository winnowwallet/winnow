# Winnow Lightning encryption inventory for review

Source: `1f1bfdd956c84765c444ed6b0667806b20626c55`. Bundle: `com.btcswift.lightning`. Configuration: `ResearchRelease`. Prepared from source on September 27, 2026 (America/New_York).

This records implementation facts for the responsible export reviewer. It is not an exemption determination, an approved Apple declaration, or evidence that distribution requirements have been satisfied. The release evidence remains pending.

## Components in the app

| Use | Algorithms and implementation | Source evidence |
| --- | --- | --- |
| Lightning peer transport | Noise XK with secp256k1 ECDH through P256K/libsecp256k1; SHA-256, HKDF-SHA256 and ChaCha20-Poly1305 through Apple CryptoKit. Traffic keys are 256 bits. | [NoiseCrypto.swift](https://github.com/posix4e/winnow-lightning/blob/1f1bfdd956c84765c444ed6b0667806b20626c55/Sources/LightningCore/NoiseCrypto.swift), [LightningHandshake.swift](https://github.com/posix4e/winnow-lightning/blob/1f1bfdd956c84765c444ed6b0667806b20626c55/Sources/LightningCore/LightningHandshake.swift) |
| Onion routing | BOLT 4 Sphinx packets use secp256k1 ECDH, HMAC-SHA256 and a 256-bit ChaCha20 stream. The stream primitive is implemented in Swift in `OnionStream`; it is not supplied by CryptoKit. | [OnionPacket.swift](https://github.com/posix4e/winnow-lightning/blob/1f1bfdd956c84765c444ed6b0667806b20626c55/Sources/LightningCore/OnionPacket.swift) |
| Channel and offer signatures | secp256k1 ECDSA and Schnorr through P256K/libsecp256k1; channel key derivation and SHA-256 hashing. | [ChannelKeys.swift](https://github.com/posix4e/winnow-lightning/blob/1f1bfdd956c84765c444ed6b0667806b20626c55/Sources/LightningCore/ChannelKeys.swift), [Bolt12Encoding.swift](https://github.com/posix4e/winnow-lightning/blob/1f1bfdd956c84765c444ed6b0667806b20626c55/Sources/LightningCore/Bolt12Encoding.swift) |
| Channel journal confidentiality and integrity | Apple CryptoKit AES-GCM using a 256-bit key. The full journal uses complete iOS file protection and a WhenUnlockedThisDeviceOnly key. A separate AES-GCM journal holds pre-signed recovery transactions and public chain observations, using complete-until-first-unlock file protection and its own AfterFirstUnlockThisDeviceOnly key. No wallet seed, node/channel private key or revocation secret is written into the recovery journal. | [LightningJournal.swift](https://github.com/posix4e/winnow-lightning/blob/1f1bfdd956c84765c444ed6b0667806b20626c55/Sources/LightningCore/LightningJournal.swift) |
| Existing wallet crypto | Winnow WalletCore supplies transaction signing, BIP32/BIP39/BIP86 keys, hashing, and Keychain storage. WalletCore also contains AES-GCM backup code, although research app iCloud backup is disabled. The review must consider linked code, not only visible Lightning screens. | [WalletCore](https://github.com/posix4e/winnow-lightning/tree/1f1bfdd956c84765c444ed6b0667806b20626c55/Sources/WalletCore), [project.yml](https://github.com/posix4e/winnow-lightning/blob/1f1bfdd956c84765c444ed6b0667806b20626c55/project.yml) |

The only pinned Swift package dependency is `swift-secp256k1` 0.23.2, revision `e70a10e036a55fffea31568f0af92d69b6d449cd`. It exposes the C libsecp256k1 implementation through P256K. [Dependency lockfile](https://github.com/posix4e/winnow-lightning/blob/1f1bfdd956c84765c444ed6b0667806b20626c55/Package.resolved).

LDK/Rust, Core Lightning and Bitcoin Core are independent host test references. They are not app runtime dependencies. Removing Rust does not remove encryption implemented outside the Apple operating system.

## Distribution determination still needed

Apple distinguishes encryption supplied only by the operating system from industry-standard algorithms implemented outside it. Its documentation table also identifies a French declaration requirement conditional on App Store distribution in France. That table alone is not a complete determination for this app or its TestFlight distribution. [Apple encryption documentation reference](https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption).

Use the existing app's App Information → App Encryption Documentation questionnaire, or the affected build's encryption questions, to establish the required documentation. Retain the determination and any approved declaration with this exact source and intended distribution. [Apple submission procedure](https://developer.apple.com/help/app-store-connect/manage-app-information/determine-and-upload-app-encryption-documentation).

`ResearchRelease` defaults `ITSAppUsesNonExemptEncryption` to `YES` pending review. The release script verifies either a documented exemption or an approved declaration belonging to App Store Connect app `6815392502`. The ordinary wallet configuration still defaults to `NO` and also links LightningCore; this inventory must not be treated as approval to distribute that separate bundle unchanged.

No country availability settings or export declarations were changed. The inventory records no conclusion that China or France categorically prohibits this app. The reviewer still needs the responsible entity, applicable classification/reporting basis, intended destinations and supporting documentation.

## Changes since the previous internal beta

Compared with TestFlight 0.3.0 build 7, the new BOLT11 sender and bounded BOLT7
routing cache reuse existing secp256k1 ECDSA, hashing and Sphinx primitives. The
new explicit invoice-payee verifier calls the existing library's ECDSA verify
primitive. No new cryptographic algorithm, key size or third-party dependency
is introduced. Camera scanning uses Apple's VisionKit and AVFoundation.
The transport, onion packet, journal crypto, channel keys, dependency pins,
and WalletCore crypto/key implementations remain byte-for-byte unchanged;
`crypto-comparison.json` retains their hashes and all changed paths. A separate
WalletCore FilterSync change improves stalled-peer recovery and introduces no
crypto implementation. Product wording describes generic payment wallets.

The authorized scope remains international internal TestFlight with no public
App Store release. The questionnaire flow rechecks current app distribution
state and the exact processed build before tester assignment. Build 7's
receipt is historical and cannot establish build 8's availability. Physical
camera, authentication and locked-device enforcement remain hardware checks.
