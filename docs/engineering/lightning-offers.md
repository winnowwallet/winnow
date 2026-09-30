# Ordinary Lightning offers and payment names

The standard BOLT12 flow publishes a reusable `lno` offer, sends a signed invoice
request over an onion message, receives a signed `lni` invoice, and pays that
invoice through its blinded payment path. It requires the recipient to be online
to issue the invoice and receive its payment. The existing provider-assisted
async offer/static-invoice flow remains a separate feature.

Winnow first obtains and validates the recipient's invoice. It binds the exact
offer and payer request, expected issuer, selected network, amount and expiry,
then finds a route and presents the fee limit for review. Authentication and a
second current quote check precede durable HTLC authorization. Requests, received
invoices and authorized payments persist in the existing encrypted journal;
retrying one request ID cannot authorize a second payment. Pending requests
expire after five minutes and can be canceled without erasing an authorized
payment.

Receiving standard offers requires a confirmed channel, verified chain and
current signed receiving policy. Offers include either a public issuer identity
or an authenticated blinded path through the provider. Invoice payment paths use
standard BOLT4 encrypted forwarding data and a recipient-owned path token; they
do not use async preimage or release fields. In Advanced mode, open Lightning,
then use Create reusable offer in the Receive section and Share reusable offer
or Copy reusable offer. The separate Receive Lightning screen creates BOLT11
invoices.

Enter an `lno` offer or `₿user@domain` in Pay reusable offer. BIP353 resolves the
name's TXT payment URI, follows signed CNAME/DNAME aliases, and verifies DNSSEC
signatures and delegations locally against pinned IANA root DS records. The
resolver is an untrusted record transport, and its authentication claim is not
used. DNS TTLs, signature expiration and offer expiry bound the result; an
expired result must be resolved again before payment approval. The original
name is signed into the invoice request. This implementation accepts ASCII DNS
names, including explicit punycode, and rejects Unicode spellings.

This first standard-offer implementation supports bitcoin amounts and single
part payments. Currency conversion, quantities, compulsory multipart payments,
offer-less refund negotiation and arbitrary unsolicited invoices are unsupported.
An invoice with an unsupported blinded-path feature can still use another signed
path that the client supports. Recovery-only restored backups cannot request,
issue or pay invoices.

Validation commands:

```sh
swift test --filter 'OrdinaryOfferTests|BIP353Tests|DNSSECPrimitiveTests|RoutingGraphTests|PeerSessionTests'
WINNOW_CLN_DIR=/path/to/lightning WINNOW_BITCOIN_DIR=/path/to/bitcoin/bin \
  scripts/ci-lightning-peer --close cooperative --offers
swift run winnow-lightning-peer-fixture probe-bip353 matt@mattcorallo.com
```

The stock-peer check uses unmodified Core Lightning v26.06.8 and real BOLT8 TCP.
Its receipt records a direct and a blinded ordinary payment in each direction,
with CLN's independent offer decoding, invoice/payment state, hashes, preimages
and balances. It asserts the actual `offer_paths` field distinguishes direct
issuer requests from blinded introductions, then restarts Winnow and checks all
four settled payment records again. The reference uses advertised loopback
addresses and stock development options; it changes no reference protocol code.
The DNSSEC suite uses published BIP353 proofs plus locally signed DNAME and key
algorithm tests; a live probe checks the complete resolver against a public
name without sending a payment. These checks do not establish TestFlight release
readiness or physical-device background protection.

Primary specifications: [BOLT12](https://github.com/lightning/bolts/blob/master/12-offer-encoding.md),
[BOLT4](https://github.com/lightning/bolts/blob/master/04-onion-routing.md),
[BIP353](https://github.com/bitcoin/bips/blob/master/bip-0353.mediawiki), and
[DNSSEC validation](https://www.rfc-editor.org/rfc/rfc4035).
