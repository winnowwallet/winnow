# Lightning receiving and provider setup

Both wallet modes offer **Receive → Lightning or Bitcoin**. Bitcoin continues
to show a Winnow address. Lightning shows a standard BOLT11 invoice for a
specific amount once a confirmed channel has usable inbound capacity and a
signed routing policy. An empty wallet does not invent capacity or an invoice.
A Lightning withdrawal uses the Lightning invoice; an on-chain withdrawal
uses the Bitcoin address. Copy and Share preserve the exact invoice bytes.

Fresh mainnet wallets recommend Megalith Instant. The provider picker contains
four choices, connects to one, and opens no channels or makes payments just
because a choice is selected. A wallet that already used a provider (a channel
with it, or a stored setup order) keeps it when the default changes.

| Provider | Setup |
| --- | --- |
| Megalith Instant | LSPS2 (bLIP-52) just-in-time channels over the authenticated Lightning connection |
| Olympus by ZEUS | LSPS1 quotes over the authenticated Lightning connection |
| Megalith | LSPS1 quotes over its HTTPS API while the Lightning peer is connected |
| LNServer Wave | Clearly labeled website setup; copy the durable wallet node ID and choose a private channel |

## Instant receive (LSPS2)

With Megalith Instant and no receiving capacity, the first receive is one
invoice:

1. Enter the amount and tap **Show the provider's fee**. Winnow reads the
   provider's fee menu (`lsps2.get_info`) and shows what the provider keeps,
   what arrives, and how long it promises to keep the channel open.
2. Approve with Face ID. Only then does Winnow reserve the channel
   (`lsps2.buy`) and show the invoice. Its one route hint names the provider's
   intercept scid with zero fees; it expires before the fee terms do, and its
   final CLTV delta is 20 (18 plus the two blocks bLIP-52 adds).
3. The payer pays it. The provider opens a private channel to Winnow and
   forwards the payment minus its fee, declaring the fee in `update_add_htlc`'s
   `extra_fee` TLV (65537). Winnow accepts that channel before it confirms and
   claims the payment.

What Winnow checks:

- **Zero-conf is granted, not inferred.** Only an `open_channel` from the
  provider Winnow bought from, private, with no push, at least as large as the
  payment minus the fee, for a purchase that is live and not already bound,
  gets the grant. It is a persisted per-channel field; `fundingIsConfirmed`
  keeps its meaning, so a remote `channel_ready` is still never evidence of
  funding for any other channel. A `channel_type` with option_zeroconf and no
  matching purchase is refused.
- **The fee.** The payment is claimed only if the HTLC plus the declared
  `extra_fee` covers the invoice amount and the fee is at most the agreed
  opening fee. Ordinary invoices ignore `extra_fee`.
- **Recovery is set at acceptance**, so the payment can be claimed the moment
  it arrives, and the bought channel skips the full rescan an ordinary new
  funding triggers: its funding cannot already be in a scanned block, and the
  rescan would outlast the provider's forwarding window.
- **Aliases.** Winnow sends its own alias in `channel_ready` and keeps the
  provider's. Before confirmation (and for scid-privacy channels after it),
  the next invoice's route hint names the provider's alias; its policy is the
  provider's `channel_update` for any of the channel's identifiers.

Until the funding confirms, Winnow trusts the provider with what the channel
holds. Megalith answers `client_trusts_lsp: true`: it publishes the funding
only after Winnow releases the preimage, so a provider that never publishes
keeps the payment. The channel row says "confirming · trusted provider" until
then. A bought channel whose funding never appears and which holds nothing of
ours is forgotten after 2016 blocks; one holding a payment never is.

The invoice is fixed-amount but does not set `basic_mpp`, so payers send one
part: Winnow does not yet combine multi-part receives. This differs from
bLIP-52's fixed-amount mode, which allows MPP. The first payment must leave at
least a 20,000-sat channel after the fee; with Megalith's terms (3,514 sats or
1.4%) that is 23,514 sats.

CI pays Winnow's instant invoice through stock LDK's `lightning-liquidity`
LSPS2 service (`scripts/ci-lightning-jit`, in `posix4e/lightning-reference`'s
`lsps2` role): with the provider broadcasting or the client trusting it, with
and without scid privacy, and on a zero-reserve anchor channel.

## Buying capacity ahead (LSPS1)

Olympus and Megalith return live capacity limits and a separate setup fee invoice.
Review the fee, capacity, lease and confirmation count. Approving the fee requires
device authentication and reveals that invoice; it does **not** pay it. Pay it
from another Lightning wallet. The setup fee buys inbound capacity,
not wallet balance. Check setup status and sync before creating a receive invoice.
Orders and approval survive restart in a sealed, device-protected file. Providers
cannot be changed while an approved order or an existing channel remains active.
Paid or expired fee invoices cannot be offered again as payable invoices.

LNServer quotes and payment approval happen on its website. Winnow does not
claim an in-app quote integration for that provider. Reopen Winnow to sync the
funding transaction and establish receiving capacity.

Purchases request a private channel, zero initial client balance, and at least
three confirmations. Megalith receives the nonempty `Winnow` token described in
its compatibility documentation to avoid zero-reserve channels that violate
the wallet's dust checks. Mainnet services are never defaults on signet/regtest.
Advanced profile import and the existing BOLT12 async offers remain available.

Invoices use Winnow's Bech32 and bit-conversion code, the existing pinned
libsecp256k1 dependency, and the Swift engine's durable payment machinery. Route
hints bind the provider's signature and policy to the funding transaction's
verified block position. Older journals lacking a position request a rescan.
Wall-clock invoice expiry is also persisted and checked when accepting payment.

This remains an experimental Lightning engine. Keep the app open for ordinary
BOLT11 receiving. A default provider does not provide external watchtower
protection; iOS background checks run only when permitted. Public connection and
unpaid-quote diagnostics are separate from funded mainnet payment validation.

Provider warnings are retained separately from connection failures. BOLT 1
warnings do not themselves close the session; errors referring to this peer's
channels stop the session and retain the provider's printable reason. Notices
for unknown channels are ignored. Displayed provider text is capped at 240
characters, and non-printable data is hidden. This diagnostic handling does not
delete channel state or authorize funding, setup payments, or recovery spends.
During a verified chain scan, the transport continues answering keepalives and
reading provider notices. Financial messages wait in a bounded, ordered queue
(128 messages / 1 MiB) until the engine verifies the chain again. Overflow
disconnects rather than accepting financial work against an unverified chain.

Manual channel funding starts with an empty capacity field. This spending setup
is separate from buying provider-funded receiving capacity. Opening and accepted
negotiations do not report proposed allocations as local balances. A balance
requires a funding outpoint and an enforceable peer-signed commitment; recovery
destinations can still be configured before funding. Receiving status distinguishes
unfinished negotiation, funding signatures, confirmations, and routing capacity.

A provider error declining a locally initiated request still in `opening` marks
that unfunded request closed and removes its queued messages. Reconnecting or
restarting cannot replay it indefinitely. Its history remains in the journal.
This rejection path cannot close or discard enforceable funded channels.

The host-only `winnow-lightning-peer-fixture probe-lsp-stability HOST PORT PEER
[API]` command authenticates a temporary node, requests provider information,
and checks that the session stays connected for 60 seconds. It does not request
a channel, create an order, or send funds. A passing result is a connection
diagnostic, not a mainnet receiving or chain-validation receipt.
`probe-lsp-opening` makes a temporary 100,000-sat negotiation request, supplies no
funding or signatures, and checks reconnection if the provider rejects it. A
provider's direct-funding minimum can differ from its LSPS1 capacity minimum.

Before the first verified Bitcoin scan, provider setup explains that the chain
check is still pending. It cannot misreport an unstarted connection as lack of
provider support. The previous scan error remains in diagnostics but is not
presented as current during a retry; an old no-peers error also disappears once
the live connection phase shows peers. Verification failures remain visible.
Filter-body and matched-block transport failures disconnect and cool down the
serving peer, preserving completed batches for the next scan with another peer.

`LightningAppUITests.testLiveMainnetSyncAndUnpaidReceivingQuote` is a manual
public-network diagnostic. Set `WINNOW_LIVE_MAINNET=1` in the XCTest runner's
test environment and select that test in the WinnowLightning scheme. Each run
uses a new storage/Keychain namespace and ordinary public peers and the signed
Winnow census. It verifies a complete chain scan and an unpaid Olympus quote;
it never approves a fee or exposes an approved payment invoice. Its known debug
seed must never receive real funds. Provider outages do not fail deterministic
CI, where this one case explicitly skips without the opt-in. Local results and
recordings are evidence of the diagnostic only, not a funded mainnet payment,
TestFlight release, or physical-device authentication/storage validation.

Primary contracts:

- [BOLT11](https://github.com/lightning/bolts/blob/master/11-payment-encoding.md)
- [BOLT 1 peer warnings and errors](https://github.com/lightning/bolts/blob/master/01-messaging.md#the-error-and-warning-messages)
- [LSPS1](https://github.com/lightning/blips/blob/master/blip-0051.md)
- [Olympus](https://docs.zeusln.app/lsp/services/lsps1/)
- [Megalith](https://docs.megalithic.me/lightning-services/lsp1-get-inbound-liquidity-for-mobile-clients/)
- [LNServer](https://lnserver.com/)
# Channel check warnings

Funded channels retain a per-network last-complete-check record on this device.
A warning is visible in both Simple and Advanced modes before the first complete
channel check, after a failed scan or recovery relay, after one hour without a
complete check, and with stronger wording after six hours. Switching networks
does not erase another network's warning. Only a complete verified channel scan
refreshes the record; peer connectivity does not. Recovery broadcasts must be
requested by a Bitcoin peer before that scan can count as complete.

Reminders require an explicit tap and Apple's notification permission. Two local
notifications are queued while the app is running, so delivery does not require
a later background execution. A failed check or recovery relay also queues a
single immediate reminder for that check, without repeating on every retry.
Rechecking replaces old requests; a verified
cooperative close cancels that network's reminders. Reopening the app does not
repeat a notification already queued for the same check. Permission denial and
scheduling errors retain the in-app warning. Notification text excludes balances,
payment details and node identity.

One and six hours are reminder intervals, never promises about safe offline time.
Deadlines depend on channel timelocks measured in blocks. iOS can silence or delay
notifications and does not guarantee background checks. These reminders are not
a watchtower and cannot scan, sign, or relay a justice transaction by themselves.
Other networks remain warned but automatic background scans still cover only the
selected network; the warning's Check action opens the network that is overdue.
