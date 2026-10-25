[Back to main README](../../../README.md)

# Wallet and network reference data

These fixtures provide BIP158 filters, BIP341 signing examples, controlled DNS
replies, and real mainnet headers. They give wallet/network tests stable inputs
without querying a changing public service during each run.

[SighashBIP341Tests](../SighashBIP341Tests.swift),
[PeerPolicyTests](../Network/PeerPolicyTests.swift), and
[HeaderChainTests](../Network/HeaderChainTests.swift) are consumers.
SwiftPM copies the directory into the test resource bundle.

`bip341-scriptpath-test-vectors.json` is a `tr(NUMS, multi_a(2, K1, K2, K3))`
spend generated once with Bitcoin Core's functional-test framework, for the
script-path sighash (BIP342 ext_flag 1) across all eight hash types with and
without an annex: the SigMsg bytes, sighashes, signatures under zero auxiliary
randomness, and the BIP387 witness. It is carried over unchanged from the
shared-account Winnow; the native signer must reproduce its signatures byte
for byte.

`core-timelocked-multisig.json` holds Bitcoin Core 31.1's answers for four
multipath descriptors with a timelocked recovery leaf (a separate key, the same
signers on `/<2;3>/*`, a three-block lock and the maximum lock with the recovery
leaf first): `getdescriptorinfo` checksums and `deriveaddresses` for both
choices at indices 0 to 2, recorded once on a throwaway regtest node over
public test keys from Ledger's vectors. [TimelockedMultisigTests](../TimelockedMultisigTests.swift)
recomputes each.

`difficulty-boundaries.json` holds the period-start, previous, and adjustment
headers for mainnet heights 32,256 and 901,152. Retrieved on 2026-09-09 through
[Blockstream's block API](https://github.com/Blockstream/esplora/blob/master/API.md#blocks):
resolve each height with `/block-height/:height`, then fetch `/block/:hash/header`.
Each serialized header's double-SHA256 was checked against its returned block hash.
[HeaderDifficultyTests](../Network/HeaderDifficultyTests.swift) checks proof of work,
the adjacent headers' linkage, and the calculated adjustment. Its fixed Core
calculation vectors come from [Bitcoin Core v31.0 pow_tests.cpp](https://github.com/bitcoin/bitcoin/blob/v31.0/src/test/pow_tests.cpp).

`rfc9180-x25519-vectors.json` is the subset of the HPKE working group's
`test-vectors.json` (github.com/cfrg/draft-irtf-cfrg-hpke, `master` on
2026-10-25, whole-file SHA-256 `61fc662f01996cd06d713dacf5e133167bd309a1f329442d53f1e21a47b3ede6`,
5,892,257 bytes) with `kem_id` 0x0020, `kdf_id` 0x0001 and `aead_id` 0x0001
or 0x0003: eight entries, one per mode and AEAD, written with `json.dumps(...,
indent=1, sort_keys=True)` (SHA-256 `50b3d47df22fb6482867d443e317b411fbc7ab3f705d1e6868ebdd5c95b99119`).
[HPKETests](../HPKETests.swift) runs every setup, encryption and export in it.
`draft-wahby-cfrg-hpke-kem-secp256k1-01.txt` is the secp256k1 KEM draft as
published at ietf.org (SHA-256 `e860b8968bf375e8fb9de6e19670ced4964602ccae42be5e35084128833781cd`);
the same suite parses its Appendix B. Its Auth cases print the recipient's key
pair under `skSm`/`pkSm`, but their outputs were computed with the sender key
`DeriveKeyPair` gives for `ikmS`, which is what the test uses.
`ellswift_decode_test_vectors.csv` and `xswiftec_inv_test_vectors.csv` are
bitcoin/bips `bip-0324/` at commit `100ba872c808946155b1eeb8c4568058f2eea0a7`
(blobs `1bab96b721e2f3ab90142c318523551eb520f753` and
`138c4cf85c040785a45c6552c0169c8c12fd3cfc`), run by
[ElligatorSwiftTests](../ElligatorSwiftTests.swift). RFC 9458's Appendix A
example and BIP 78's PSBT vectors are short enough to sit in
[OHTTPTests](../OHTTPTests.swift) and
[PayjoinProposalTests](../PayjoinProposalTests.swift) with their section
references.

Refresh Bitcoin vectors from their named specifications and record the source
revision; DNS JSON files are deliberately controlled response fixtures.
The 2,000-header file is produced by the [checkpoint generator](../../../Tools/Generate/README.md)
from a genesis-validated header file. Preserve that provenance and run
`swift test --filter WalletCoreTests`; do not replace expected data just to make tests pass.
