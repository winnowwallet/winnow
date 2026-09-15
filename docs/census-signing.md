# Census signing

The peer census (`https://census.winnowwallet.com/census/peers.json`, published
from [winnowwallet/census](https://github.com/winnowwallet/census)) is the
wallet's discovery input: the bundled fallback peers are generated from it at
release, and Settings can refresh it by hand. It is untrusted input by design —
every peer it names is checked against headers and filters like any other — but
IR-003 of the 2026-09-14 review showed the list reached the wallet on TLS alone,
and the release generator hashed whatever bytes arrived.

This document is the mechanism that closes that, and the three steps only the
project owner can take.

## What ships in the wallet

- `CensusSignature` (`Sources/WalletCore/Network/Peers/CensusSignature.swift`):
  an Ed25519 signature over the tag `winnow-census-peers-v1\0` and the exact
  bytes of `peers.json`, served next to it as `peers.json.sig`:

  ```json
  {"algorithm":"ed25519","publicKey":"<32 bytes hex>","signature":"<64 bytes hex>"}
  ```

- `CensusPublisher.trustedKeysHex`: the public keys the wallet accepts. **It is
  empty until the owner adds one.** While it is empty the list is accepted
  unsigned, exactly as before, so nothing breaks ahead of the key. The first key
  turns the requirement on: the manual refresh fetches `peers.json.sig` and
  refuses a list without a valid signature, the stored copy keeps its signature
  and is checked again on every load, and the release generator refuses to
  bundle an unsigned list.

- `CensusCatalogStore` also refuses a list thinner than any real census (fewer
  than 50 clearnet entries), and `RoutedHTTPClient` no longer follows a
  redirect to another host.

- `scripts/generate-fallback-peers --census-commit <sha>` takes
  `census/peers.json` as committed in the census repository at that commit,
  checks the fetched bytes against the blob id the repository's tree names
  there, verifies the signature when a key is compiled in, and records the
  commit in the bundle. `scripts/check-release-policy` requires that line, so a
  release can no longer ship a list that is not tied to a reviewable commit.

## Owner steps

1. **Make the key** (in the census checkout):

   ```bash
   swift run WinnowCensus keygen
   ```

   It prints the secret once, as `CENSUS_SIGNING_KEY=<base64>`, and the public
   key as hex. Store the secret as the census repository's `CENSUS_SIGNING_KEY`
   Actions secret. The daily census job signs `peers.json` with it after every
   accepted run; while the secret is absent the job publishes unsigned and says
   so in its log.

2. **Trust the public key** (in the wallet): add the hex to
   `CensusPublisher.trustedKeysHex` and commit. From that build on, the wallet
   and the generator require a signature.

3. **Regenerate the bundled peers** from a signed census commit before the next
   release:

   ```bash
   scripts/generate-fallback-peers --census-commit <full sha of a census commit>
   ```

Order matters only in one place: step 2 before step 1 leaves the wallet
refusing an unsigned census until the job has signed one. Do 1, wait for a
signed daily run, then 2 and 3.

## Rotation

Add the new key to `trustedKeysHex` alongside the old one, change the secret,
and remove the old key after every wallet in the field has been updated. A
signature names its key, so which one signed is visible in the file.

## Tests and E2E

`CensusSignatureTests` and `CensusCatalogStoreTests` cover signing, refusal,
and storage. The E2E journeys serve a fixture census; once a real key is
compiled in, a journey must name a test key with
`WINNOW_E2E_CENSUS_KEYS=<hex>` and sign its fixture with the matching secret,
or the refresh journey fails as designed. The E2E store has no size floor.
