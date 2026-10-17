# Satochip MuSig2 recovery lab

This development lab connects Winnow's account, backup and PSBT code to the
Satochip v0.15-0.1 applet in jCardSim. It uses the official Python client and
secure channel. It never initializes a physical card or opens a user's wallet.
All signing seeds are public test fixtures. The app has no Satochip/NFC signing
integration yet.

The native coordinator is `swift run winnow-fixture satochip-recovery`.
It creates a signet wallet, exports and decodes its manual backup and account
record, then exchanges public nonces and partial signatures with the driver.
The phone signs through VaultKit; the simulated card derives its account key
from a separately imported seed and signs inside the applet. Winnow verifies
each partial and the final BIP340 signature.

## What runs

Four scenarios cover the initial signing flow, restored phone key, replacement
card initialized from the hardware seed, and both restored. Each checks saved
account policy, coins and counters, and requires both signatures. Additional
checks reject wrong phone words, a watch-only signing restore, the wrong
hardware seed, changed payment messages, modified encrypted nonces and replayed
nonces. A simulated reset must preserve the rejection of a consumed nonce.

With `--bitcoin-bin`, a new private regtest node funds the account's output
script and calls `testmempoolaccept` for each resulting transaction. P2P is
disabled, RPC binds to loopback, all data is temporary, and payments are never
broadcast. This checks Bitcoin Core acceptance of the spending transaction; it
does not exercise the app's signet synchronization or UI. Without that option,
the outpoint is fabricated and the report explicitly omits a consensus claim.

This does not establish secure-element resistance, real power-loss behavior,
reader/NFC interoperability, iOS Keychain behavior, iCloud recovery or trusted
transaction display. Satochip's beta delegates part of the session calculation
to the host and signs without a display. Separate key custody alone does not
provide independent destination verification.

## Pinned inputs

| Input | Revision |
| --- | --- |
| [SatochipApplet](https://github.com/Toporin/SatochipApplet/releases/tag/v0.15-0.1) | `3aa97fdc32c3fe3afade3cd5eb7cd9d0d4bd197c` |
| [pysatochip](https://github.com/Toporin/pysatochip) | `49d1100054f010baae952fe1f0c1104958c0a07b` |
| jCardSim binary, `com.klinec:jcardsim:3.0.5.11` | SHA-256 `f6c3b6b8140401a47cf39d7b9dbfc052e381474c6c3b22018051024be1fca97c` |
| jCardSim sources, same version | SHA-256 `a6a0332427b4232d853a5c402cb056d82ebfdb88e765198977c803d950a19240` |

The driver refuses different or modified upstream checkouts and jars. Java 17
and Python 3.11 or later are required. Install the pinned client's Python
requirements in a dedicated virtual environment; no Java or Python dependency
is added to the shipping wallet. The software run used Python 3.12 and Bitcoin
Core 31.1.

The simulator needs a correction: its `ByteContainer.getBigInteger()` uses the
whole backing array after a shorter RSA exponent is written. The driver compiles
a temporary override that respects the active length, retaining the upstream
source and license. A 2 × 3 multiplication self-check must pass before any card
operation. The simulator also uses OS-seeded randomness, avoiding identical
wrapping keys across fresh simulated cards. These are simulator configuration
and fixes; the default applet source remains unmodified.

## Run

From the repository root, prepare a separate lab directory. Keep these cloned
dependencies and runtime files outside committed wallet source:

```sh
WINNOW_SATOCHIP_LAB=$(mktemp -d /tmp/winnow-satochip-lab-XXXXXX)
git clone https://github.com/Toporin/SatochipApplet.git "$WINNOW_SATOCHIP_LAB/applet"
git -C "$WINNOW_SATOCHIP_LAB/applet" checkout --detach 3aa97fdc32c3fe3afade3cd5eb7cd9d0d4bd197c
git clone https://github.com/Toporin/pysatochip.git "$WINNOW_SATOCHIP_LAB/client"
git -C "$WINNOW_SATOCHIP_LAB/client" checkout --detach 49d1100054f010baae952fe1f0c1104958c0a07b
python3.12 -m venv "$WINNOW_SATOCHIP_LAB/venv"
"$WINNOW_SATOCHIP_LAB/venv/bin/pip" install -r "$WINNOW_SATOCHIP_LAB/client/requirements.txt"
curl -fL https://repo.maven.apache.org/maven2/com/klinec/jcardsim/3.0.5.11/jcardsim-3.0.5.11.jar -o "$WINNOW_SATOCHIP_LAB/jcardsim.jar"
curl -fL https://repo.maven.apache.org/maven2/com/klinec/jcardsim/3.0.5.11/jcardsim-3.0.5.11-sources.jar -o "$WINNOW_SATOCHIP_LAB/jcardsim-sources.jar"
swift build --product winnow-fixture
WINNOW_FIXTURE_BIN="$(swift build --show-bin-path)/winnow-fixture"
```

Set `WINNOW_JAVA_DIR` to a Java 17 JDK's home directory, containing `bin/java`
and `bin/javac`. Then run the stock applet:

```sh
"$WINNOW_SATOCHIP_LAB/venv/bin/python" Tools/Satochip/run-recovery.py \
  --applet "$WINNOW_SATOCHIP_LAB/applet" --client "$WINNOW_SATOCHIP_LAB/client" \
  --jcardsim "$WINNOW_SATOCHIP_LAB/jcardsim.jar" \
  --jcardsim-sources "$WINNOW_SATOCHIP_LAB/jcardsim-sources.jar" \
  --java-home "$WINNOW_JAVA_DIR" --fixture "$WINNOW_FIXTURE_BIN" \
  --output "$WINNOW_SATOCHIP_LAB/stock.json"
```

The stock run completes the four signing scenarios but returns nonzero for the
counter finding below. Repeat with `--counter-fix` and a different output path
to test the proposed fix. Add `--bitcoin-bin /absolute/path/to/bitcoin/bin` for
the disposable consensus check. Reports and companion logs identify the mode,
input revisions and binary hash; a partial or failed run remains a failure.
This Java integration is an explicit development check; ordinary SwiftPM CI
runs the crypto/vector tests without downloading the applet or Java runtime.

## Observed applet limits and proposed fix

The nonce response is **68 bytes**: a BIP327 public nonce of 66 bytes followed
by a two-byte ID. Only the first 66 bytes enter the BIP373 PSBT field. The
encrypted token is 144 bytes and stays opaque to Winnow. Status words must be
checked even where the Python MuSig2 convenience methods omit that check.

Only 16 nonce IDs can remain outstanding. Generating a seventeenth evicts the
oldest; signing it then returns `9c47`. A multi-input adapter needs bounded
batching or an explicit limit, rather than generating every input's nonce first.

At counter 32,769, the stock applet's signed-short `% 16` produces a negative
array index. The simulator returns `6f00`. Boundary testing injects the counter
into simulated state; it does not perform 32,769 physical operations or change
the upstream source. [counter-index.patch](counter-index.patch) uses a mask for
the power-of-two slot count. With `--counter-fix`, the driver patches only a
temporary source copy and identifies that mode in the report. It checks both
the signed boundary and the 65,535-to-zero overflow: MAC-key rotation, rejection
of old tokens and restart at ID 1. This patch has not been applied upstream or
validated on a physical card.

## Hardware for the next stage

| Quantity | Exact requirement | Purpose |
| --- | --- | --- |
| 2 | Dedicated Satochip development cards, both with MuSig2-capable applet v0.15-0.1 or a reviewed successor; request contact + NFC interfaces | One original and one replacement restored from its seed |
| 1 | USB-C [ACS ACR39U-UF contact smart-card reader](https://www.acs.com.hk/en/products/422/acr39u-uf/), or Satochip's own tested USB reader | Mac PC/SC bench tests and real disconnect/reinsert checks |
| 1 | Mac with the reader connected | Existing software harness and future physical-card transport |
| 2 | Physical iPhones running an app-supported iOS version (17+); iPhone 12 or newer is a practical lab baseline | Original and replacement phone; NFC and iCloud recovery after the app integration exists |
| 1 set | A dedicated test Apple Account with iCloud and Passwords & Keychain enabled on both phones | Actual CloudKit and wrapping-key synchronization |
| 2 sets | Separate disposable phone and hardware-seed backups, plus the account backup | Independent recovery, without moving the hardware seed into the phone's cloud backup |

Confirm applet provisioning with the supplier before ordering. A generic retail
Satochip, a Seedkeeper or a Satodime is not evidence of this MuSig2 applet.
The [beta release](https://github.com/Toporin/SatochipApplet/releases/tag/v0.15-0.1)
and counter fix need review before treating the integration as ready for funds.
Two cards avoid erasing the original to test replacement. One card could support
an initial bench test, but cannot demonstrate recovery onto a distinct card.

[probe-card.py](probe-card.py) lists local PC/SC readers. With an explicit
`--reader-index N`, it sends only SELECT and GET STATUS and reports public
version bytes. It never requests a PIN or initializes/imports a seed. The
recovery driver itself remains simulator-only; a physical-card transport and
the app's NFC flow are subsequent work.

Use disposable development cards for provisioning and reset tests. The upstream
root hardware test scripts alter seeds and expect a preset PIN; their MuSig2
vector suite additionally requires a special debug applet. They are separate
from this lab and must not be run on a card holding funds.
