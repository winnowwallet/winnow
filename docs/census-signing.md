# Census signing

The [peer census](https://census.winnowwallet.com/census/peers.json) supplies
automatic mainnet discovery and the manual refresh in Settings. Every downloaded
list must carry an Ed25519 signature from a publisher key compiled into the
wallet. Peers remain untrusted: the wallet still validates their headers and
filters independently.

## Publisher and wallet trust

The publisher key established on September 18, 2026 is:

```text
b999d0881c236f3f38dce334bd373c75b936677bbed952685745486131d32b74
```

The private key is held in the `winnowwallet/census` repository's
`CENSUS_SIGNING_KEY` Actions secret. The public key is recorded in that
repository's `census/signing-public-key.txt` and in the wallet's
`CensusPublisher.trustedKeysHex`.

The publisher signs the tag `winnow-census-peers-v1\0` followed by the exact
bytes of `peers.json`. Its adjacent `peers.json.sig` contains:

```json
{"algorithm":"ed25519","publicKey":"<32 bytes hex>","signature":"<64 bytes hex>"}
```

Both publisher deployment paths require a signature matching the pinned key.
Missing or mismatched secrets stop daily publication; missing, modified, or
foreign signatures stop deployment. The previous published list stays in use.

The wallet requires the signature on every refresh and verifies the stored
bytes again on load. An empty trust configuration rejects every list. Old
unsigned caches are ignored; saved peers and DNS discovery remain available, and a
successful refresh replaces the cache. Signature checks supplement the
existing size, age, schema, and minimum-peer checks.

The app ships no peer-address snapshot. A fresh mainnet install automatically downloads the signed census while saved
peers and DNS discovery start independently. Missing or expired catalogs are
retried while the app is active, with at least a minute between failed attempts.
Signet does not download the mainnet census. An expired census stops
supplying new candidates; previously connected peers remain in the saved
peer cache, and DNS supplies additional candidates.

## Key rotation

1. Generate a replacement key with `WinnowCensus keygen` in a trusted local
   session. Its output includes the private key; keep it out of logs and git.
2. Ship the new public key alongside the old key in the wallet. Wait until
   supported wallet versions trust it before switching the publisher.
3. Replace the publisher's Actions secret and commit the matching public key
   and newly signed list together. Verify the deployed bytes and signature.
4. Remove the old wallet key when it is no longer needed for supported data.

Publish signed data before shipping a wallet that requires its key. If the
secret is lost, use this rotation process; never restore unsigned acceptance.

## Checks

The publisher's contract tests verify its committed catalog, missing and
modified signatures, foreign keys, and a known-answer signature shared with
the wallet. Wallet tests cover signature refusal, empty trust, unsigned legacy
caches, signed storage/expiry, and DNS bootstrap without a census.

The single payment journey does not need a separate census-refresh journey.
Any lower-level or Debug fixture that refreshes a census must sign it with a
test key and set `WINNOW_E2E_CENSUS_KEYS=<hex>`; production keys and secrets are
never used by fixtures. An empty override does not disable verification.
