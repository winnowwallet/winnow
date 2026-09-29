# Paying a Lightning invoice

Both wallet modes expose **Send → Pay Lightning invoice**. Advanced mode also
has the same action in the Lightning tab. Paste the invoice or scan its QR code;
scanning only fills the editable form. A device without supported camera scanning
can paste instead. A `lightning:` URI and uppercase BOLT11 invoice are accepted.

A fixed invoice amount cannot be overridden. For an amountless invoice, enter
sats with up to three decimal places. Review the amount, exact routing fee,
maximum fee, total, expiry, and recipient before approving with device-owner
authentication. Canceling review or authentication creates no payment intent.
Changing the wallet network or stopping the controller invalidates approval.
**Settled** is the receipt; an in-flight HTLC is still pending. A failed payment
requires another review. The request and payment ID survive restart together,
so replaying the same request cannot send another HTLC.

Paying spends the local balance of a confirmed, connected Lightning channel.
Bitcoin wallet balance and inbound receiving capacity are separate. To test
with another wallet, first complete receiving setup, create a small receive
invoice, pay it from the other wallet, and wait for settlement. Then obtain a
fresh invoice from that wallet and pay it in Winnow. Keep Winnow open for both
payments and continue checking funded channels afterward. Record the setup fee,
amount, routing fee, hashes, and both wallets' settled receipts. Mainnet tests
use real bitcoin; regtest results do not establish funded mainnet validation.

## Native engine and routing

BOLT11 decoding reuses Winnow's Bech32/bit conversion and the existing pinned
secp256k1 implementation. Explicit payee keys use low-S ECDSA verification;
otherwise the signing key is recovered. Network, signature, payment secret,
required features, amount, expiry, and CLTV bounds are checked before payment.
The sender supports a single-part TLV payment, payment metadata, and a full-amount
basic-MPP payload. Unsupported mandatory features are rejected.

Direct peer invoices and private route hints avoid downloading a graph. Other
invoices query the authenticated peer using BOLT7, check all announcement and
policy signatures, and search backwards for a route within the user's limits.
Routing announcements remain untrusted hints: they are never rebroadcast or
credited as verified funding. Winnow validates its own channel's funding and
prospective balance, reserves, and negotiated HTLC limits separately. The graph
is bounded and ephemeral, cached for ten minutes, and discarded after a failed
invoice payment. Queries are serialized; canceling discovery still drains the
outstanding reply so it cannot overlap a subsequent query. Ping/control traffic
continues during discovery and chain scanning. No HTTP route service or Rust
runtime is added.

General pathfinding uses up to 19 forwarding hops, signed public policies,
private hints, and amount/fee/CLTV bounds. Payments do not split across routes or
automatically retry. A stale policy or unavailable path can fail; the user must
review a new attempt. On-chain justice/recovery and background monitoring retain
the existing channel engine and Winnow chain scanner.

## Verification

`InvoiceSendingTests`, `RoutingGraphTests`, `ChannelEngineTests`, and
`PeerSessionTests` cover decoding/feature rejection, precise amounts, onion hops,
fees, CLTV, signed policies, query cancellation/timeouts, idempotency, restart,
settlement, and storage failure. `LightningAppTests` covers canceled and stale
invoice authentication without journal mutation.

`scripts/ci-lightning-peer` pays raw invoices issued by unmodified Core Lightning,
checks independent paid receipts, and tests process restart and enforceable
close. The cooperative run also opens a public channel between two stock nodes;
the production Swift session discovers the route and the second node receives
the forwarded payment. `scripts/ci-lightning-ui` records Simple-mode entry,
scanner fallback, canceled review, approved payment, independent reference-node
receipt, and restored history in addition to the existing async/crash journey.
Its macOS UI BOLT11 peer uses released CLN with an isolated HSM override containing
only the exact, unmerged upstream PR9564 patch; the distinct manifest and receipt
qualify that result. This is separate from the unchanged released stock CLI gates
above. See [the reference scope](lightning-roadmap.md) for the patch and provenance.
Physical camera/authentication and funded mainnet checks remain separate.

References: [BOLT11](https://github.com/lightning/bolts/blob/master/11-payment-encoding.md),
[BOLT7](https://github.com/lightning/bolts/blob/master/07-routing-gossip.md),
and [BOLT4](https://github.com/lightning/bolts/blob/master/04-onion-routing.md).
