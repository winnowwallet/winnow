[Back to main README](../../../README.md)

# Wallet keys and secret storage

BIP39 recovery words, BIP32 derivation, BIP86 addresses, and the Apple Keychain
implementation live together. Receiving, recovery, and signing use the same
keys; durable secrets retain access rules distinct from ordinary wallet metadata:
this device only, never synchronized, and behind the Keychain's own
user-presence check, which reuses the device-owner check the app just ran so
the user is asked once.
Seed derivation normalizes the recovery words and the passphrase NFKD, as BIP39
requires. For English words with no passphrase NFD gives the same bytes; a
sentence separated by U+3000 IDEOGRAPHIC SPACE, or a passphrase carrying a
ligature or a fullwidth character, derives a different seed under NFD, one no
other wallet agrees with, and nothing about the phrase itself would look wrong.

Other wallets' single-key accounts reach the same primitives. `AccountPurpose`
names the BIP44, BIP49, BIP84 and BIP86 account paths. `ExtendedKeyVersion`
reads and writes the SLIP-0132 version bytes an account key arrives under
(`ypub`, `zpub`, their multisig and testnet forms), while `HDKey.deserialize`
and the descriptor parser keep accepting BIP32's xpub and tpub only. `WIF`
decodes and encodes one private key with its network and compression flag and
refuses a key from the wrong network by name; `MiniPrivateKey` turns a
Casascius mini key into a secret. These are derivations and encodings only:
the P2PKH, nested and native segwit scripts they lead to, and signatures over
them, are not here, and Winnow's own wallet stays BIP86 under xpub and xprv.

An embedding application can keep its root secret outside WalletCore and call
`Wallet.create(accountKey:masterFingerprint:network:keyStore:...)` with only the
private BIP86 account key. It supplies the key at
`m/86'/coin_type'/account'` and the master fingerprint separately: a BIP32 child
records its parent's fingerprint, not the master's. The caller owns the declared
ancestry; the child key alone cannot prove it. See
[BIP86](https://github.com/bitcoin/bips/blob/master/bip-0086.mediawiki) and
[BIP32](https://github.com/bitcoin/bips/blob/master/bip-0032.mediawiki).

Signing resolves a mnemonic or master key down the descriptor's origin, or uses
an account key at that origin without repeating the hardened derivation. Every
loaded signing key must match the descriptor's account xpub. An account secret
also has to match its declared master fingerprint, depth and account index.
The store is read once per signing operation; no private key is held in wallet
state. Account keys cannot authorize operations that need a root key.

`WalletSecret.accountKey` uses the tagged encoding `account/1`, an eight-digit
lowercase hexadecimal master fingerprint, and an account xprv on separate lines.
The existing mnemonic and master-xprv encodings retain their bytes. Unsupported
account-secret versions are refused without exposing key payloads in errors.
An account-key wallet can export its public wallet state, but requesting recovery
words fails with `mnemonicUnavailable`; an account key cannot recreate those
words. The embedding application retains responsibility for its signing backup.

The [wallet](../Wallet/README.md), [signer](../Transactions/README.md), and
[app](../../WinnowApp/README.md) use this code. The in-memory keystore stays in
[TestSupport](../../../Tests/Support/README.md), outside production sources.

[BIP39](../../../Tests/BitcoinCoreTests/BIP39Tests.swift),
[BIP32](../../../Tests/BitcoinCoreTests/BIP32Tests.swift),
[BIP86](../../../Tests/BitcoinCoreTests/BIP86Tests.swift),
[BIP49](../../../Tests/BitcoinCoreTests/BIP49Tests.swift),
[BIP84](../../../Tests/BitcoinCoreTests/BIP84Tests.swift),
[SLIP-0132](../../../Tests/BitcoinCoreTests/SLIP132Tests.swift),
[WIF](../../../Tests/BitcoinCoreTests/WIFTests.swift) and
[mini key](../../../Tests/BitcoinCoreTests/MiniPrivateKeyTests.swift) tests check
independent vectors: the BIP texts, the SLIP's table and vectors, Bitcoin Core's
key_io files and the wiki's mini keys.
[KeyStore tests](../../../Tests/WalletCoreTests/KeyStoreTests.swift),
[Keychain attributes](../../../AppTests/KeychainAttributeTests.swift), and
[device authentication](../../../AppTests/DeviceAuthenticationTests.swift) check
storage and app integration. Device-lock enforcement needs physical-device evidence.

Automatic [iCloud backup](../../../CloudKit/README.md), on by default with a
switch in Advanced, is separate from this local signing store. Its encrypted
backup includes the mnemonic and uses a dedicated synchronizable wrapping key; it never changes the
local signing key attributes.
