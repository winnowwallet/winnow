[Back to main README](../../README.md)

# Satochip checker and card setup

A raw MuSig2 account between Winnow on an iPhone and a Satochip card is only
as strong as what decides the card's signatures. The card has no screen and
signs whatever its host asks, unless its 2FA is on: then it signs only with an
approval made with a secret it shares with one other device. `winnow-checker`
is that device, on a Mac you trust. It sets the card up once, then for every
spend reads the PSBT, works out from it alone what the payment does, shows
it, and prints approvals only after you type APPROVE. Stealing from the
account then takes the iPhone and this Mac (or the card's Seedkeeper backup),
not either alone. The design and its sources are in
[the design note](../../docs/satochip-musig2.md).

This first version runs the setup with Satochip's own tool,
[pysatochip](https://github.com/Toporin/pysatochip), and keeps the checker on
the Mac. The phone never sees the card's seed or its 2FA secret.

## What you need

- A Satochip running applet protocol 0.16 (`v0.16-0.1`, a prerelease; retail
  cards carry older locked firmware, so today this means installing it on a
  blank JavaCard such as an NXP JCOP4 J3R180), and a Seedkeeper.
- A USB smart-card reader on the Mac.
- pysatochip `v0.18.5` (49d1100) cloned on the Mac, its requirements installed
  in a virtual environment; it runs as `python satochip_cli.py <command>`.
- `scripts/winnow-checker` from this checkout (`swift run winnow-checker`).

Use test cards on signet first. Every command below talks to the one card in
the reader; swap cards when the step says so.

## Once: set up the cards

1. **Set up both cards** (PIN and PUK): `common-initial-setup`, once with the
   Satochip and once with the Seedkeeper in the reader.
2. **Create the card's seed on the Seedkeeper**: `seedkeeper-generate-masterseed
   --label "winnow card seed" --export-rights <Encrypted export only> --size 64`.
   Encrypted-only export means the seed can leave the Seedkeeper only
   encrypted to a paired Satochip. The Seedkeeper is then the seed's backup:
   keep it apart from the phone, and consider a second one.
3. **Create the 2FA secret on the Seedkeeper**: `seedkeeper-generate-2fa-secret
   --label "winnow checker" --export-rights <Plaintext export allowed>`, so
   the checker can read it in step 6. (pysatochip prints the exact spellings
   it accepts for `--export-rights`.)
4. **Pair the cards**, so the Seedkeeper encrypts to this Satochip and no one
   else. Export the Satochip's authentikey (`common-export-authentikey`, Satochip
   in the reader) and import it into the Seedkeeper as a Public Key secret
   (`seedkeeper-import-secret`). Export the Seedkeeper's authentikey the same
   way and give it to the Satochip with `satochip-import-trusted-pubkey
   --pubkey <65-byte hex>`; the Satochip accepts it only while it has no seed.
   The Mac chooses which keys are paired, which is why this runs here and
   never on the phone.
5. **Move the seed into the Satochip**: `seedkeeper-export-secret-to-satochip
   --sid <seed id> --pubkey-id <Satochip key id> > seed.json` (Seedkeeper in the
   reader), then `satochip-import-encrypted-masterseed --json-file seed.json`
   (Satochip in the reader). Delete `seed.json`.
6. **Give the 2FA secret to the checker and to the card.** Read it from the
   Seedkeeper with `seedkeeper-export-secret --sid <2FA id>` and pipe the hex
   into `scripts/winnow-checker import-key --key-file ~/winnow-checker/2fa.key`.
   Then `seedkeeper-export-secret-to-satochip --sid <2FA id> --pubkey-id <Satochip
   key id> > 2fa.json` and `satochip-import-encrypted-2fa-key --json-file 2fa.json`
   turn 2FA on in the card. Delete `2fa.json`. (Without a Seedkeeper secret,
   `winnow-checker new-key` makes one and `satochip-import-unencrypted-2fa-key`
   loads it; then the key file is the only other copy.)
7. **Read the card's keys**: `satochip-bip32-get-xpub --path m --xtype standard
   --is-mainnet False` (the master key) and the same with `--path "m/86'/1'/0'"`
   (the account key; `m/86'/0'/0'` and `--is-mainnet True` on mainnet).
8. **On the phone**, in Advanced mode, add a MuSig2 account with the card: Winnow
   reads the card's key with a tap and builds `tr(musig(PHONE,CARD)/<0;1>/*)`.
   Copy the descriptor to the Mac.
9. **Register the account with the checker**:

   ```sh
   scripts/winnow-checker register --config ~/winnow-checker/account.json \
     --key-file ~/winnow-checker/2fa.key --network signet \
     --descriptor '<the descriptor>' \
     --card-master-xpub <master xpub> --card-account-xpub <account xpub>
   ```

   The checker rebuilds the card's key expression from the xpubs it read
   itself and refuses a descriptor without it. Compare the card key and first
   address it prints with the phone before funding the account.

## Each spend

1. On the phone, create the PSBT, **Add nonce**, then **Tap card for nonce**.
2. **Copy** the PSBT; Universal Clipboard puts it on the Mac.
3. On the Mac: `scripts/winnow-checker approve --config ~/winnow-checker/account.json
   --paste --copy`. Read what it shows: every output marked AWAY leaves the
   account. Type APPROVE only if that is the payment you mean.
4. On the phone, **Paste approvals**, **Tap card to sign**, **Add partial
   signature**, then **Finalize and broadcast**.

An approval names the payment's txid and covers exactly one signing context
per input: the card refuses it for any other payment, so a phone that swaps
the payment after approval gets nothing from the card.

## Limits

- The checker trusts this Mac. If it is compromised along with the phone, the
  account is not protected.
- It looks for the account's addresses among the first `--search-limit`
  (default 500) on each chain; an input beyond that is refused, and a change
  output beyond it is shown as AWAY.
- The card can be wiped without its PIN (factory reset needs none); the
  Seedkeeper is what restores it.
- No physical card or reader has run this flow yet. The client is tested
  against a model of the applet and, separately, the real applet in a
  simulator ([Tools/Satochip](../Satochip/README.md)).

`Tests/ToolsTests/CheckerCLITests.swift` covers registration and the APPROVE
prompt; WalletCore's `SatochipCheckerTests` cover the review and that an
approval for one payment does not sign another.
