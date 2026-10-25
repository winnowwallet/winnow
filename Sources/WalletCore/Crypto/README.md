[Back to main README](../../../README.md)

# Hashing and encodings

These primitives encode addresses and keys, derive seed material, and match compact
filters. Receiving, recovery, and private chain scanning need the same byte-level
rules in the app and debugging tools.

Consumers include [key derivation](../Keys/README.md),
[Taproot scripts](../Script/README.md), and
[filter scanning](../../WalletCore/Network/Filters/README.md).
This is a source grouping inside WalletCore, not a separate service.

[Crypto tests](../../../Tests/BitcoinCoreTests/CryptoTests.swift),
[Bech32 tests](../../../Tests/BitcoinCoreTests/Bech32Tests.swift), and
[BIP158 tests](../../../Tests/BitcoinCoreTests/BIP158Tests.swift) exercise known answers
and invalid inputs. These checks support the implementation; they do not replace
an independent cryptographic review.

`TaggedHash` keeps WalletCore's `String`/`Data` interface but delegates hashing to
`P256K.SHA256.taggedHash` in the pinned secp256k1 dependency. Known-answer tests
cover empty, binary, and UTF-8 inputs; BIP341 and MuSig vector tests exercise its
protocol callers.

[Secp256k1Field](Secp256k1Field.swift) and [ElligatorSwift](ElligatorSwift.swift)
are BIP 324's encoding of a curve point as 64 bytes that pass for random: field
arithmetic mod p (not curve arithmetic, which stays in the dependency) and the
`xswiftec` forward and inverse maps, with y's parity carried on t as
libsecp256k1 does. [HPKE](HPKE.swift) is RFC 9180 with HKDF-SHA256, generic
over the KEM (secp256k1 on P256K's ECDH, X25519 from CryptoKit) and the AEAD
(ChaCha20-Poly1305 and AES-GCM from CryptoKit), and [OHTTP](OHTTP.swift) is
RFC 9458 over RFC 9292 binary HTTP, both halves. Together they are the wire
layer of [payjoin](../Payjoin/README.md). Each is held to its published
vectors: [ElligatorSwift tests](../../../Tests/WalletCoreTests/ElligatorSwiftTests.swift)
run the BIP 324 decode and inverse files, [HPKE tests](../../../Tests/WalletCoreTests/HPKETests.swift)
the RFC's X25519 cases and the secp256k1 KEM draft's, and
[OHTTP tests](../../../Tests/WalletCoreTests/OHTTPTests.swift) reproduce the
RFC's worked example byte for byte; the files and their provenance are in the
[vector README](../../../Tests/WalletCoreTests/Vectors/README.md).

The upstream Schnorr signer signs a digest supplied by the caller. WalletCore
still owns transaction signature-message construction in `SighashBIP341`, and
script-tree/control-block construction in `Taproot`; these are not replaced by
key-tweak or signature APIs.
