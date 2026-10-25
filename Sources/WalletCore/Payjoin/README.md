[Back to main README](../../../README.md)

# Payjoin, send side

BIP 77 (async payjoin, version 2) lets a receiver add its own coins to a
payment so the transaction no longer says "every input here has one owner".
The two parties never meet: the sender posts a fully signed *Original PSBT*
to a mailbox on an untrusted directory server, the receiver answers with a
*Proposal PSBT* into the sender's mailbox, and the sender checks it, signs
only its own inputs and broadcasts. Every message is end-to-end encrypted
with HPKE, and every request to the directory goes through an Oblivious HTTP
relay so neither the directory nor the receiver learns the sender's address.
Winnow sends; it does not receive, which would need a standing mailbox and
background polling.

This folder is the protocol: [PayjoinURI](PayjoinURI.swift) reads BIP 21
requests and the BIP 77 session fragment (`EX`, `OH`, `RK`, with `-` or the
earlier `+` as separator) and derives mailbox short IDs;
[PayjoinMessages](PayjoinMessages.swift) seals and opens the two 7,168-byte
messages (Base mode to the receiver key with our reply key inside; Auth mode
back, authenticated by the receiver key) with the HPKE ephemeral key written
as ElligatorSwift bytes; [PayjoinSender](PayjoinSender.swift) runs the
session — POST the original to the receiver's mailbox, GET ours until a reply
or the wait ends — inside OHTTP to `{relay}/{directory}/`; and
[PayjoinProposal](PayjoinProposal.swift) holds a proposal to BIP 78's sender
checklist: our inputs present, in order, unsigned and unchanged; the payment
output with its script kept and its value not reduced (output substitution is
always disabled, because the review bound that script); the change reduced by
at most the agreed contribution; every other input the receiver's, finalized,
with its UTXO and our sequence number; the absolute fee never lower; the
contribution spent on fees and no larger than the receiver's inputs cost at
the original rate; and `Σ our inputs − Σ our outputs ≤ amount + fee +
contribution`. The primitives live in [Crypto](../Crypto/README.md)
(HPKE, OHTTP, ElligatorSwift); [the wallet](../Wallet/README.md) builds the
sender context from a prepared send, signs a checked proposal and commits
the payjoin transaction; [the app](../../WinnowApp/README.md) binds the
proposal to the review and falls back to the original.

Where BIP 77 is silent, the reference implementation decides: the `OH`
parameter is one key-id byte plus a 33-byte key (the BIP's "2-byte" is a
slip), the relay URL form, zero padding of plaintexts, an empty Message A as
the poll's body, and the `v=2` parameter the BIP calls redundant but the
reference receiver reads. Receiver error replies are shown by BIP 78's
well-known code only; a receiver's own text never reaches the screen. A
silent payment code cannot be paid through a payjoin: the receiver's input
would change the key set the output is derived from.

[Payjoin URI tests](../../../Tests/WalletCoreTests/PayjoinURITests.swift) parse
the BIP's example and its edge cases;
[message tests](../../../Tests/WalletCoreTests/PayjoinMessageTests.swift) pin
sizes, authentication and refusals;
[proposal tests](../../../Tests/WalletCoreTests/PayjoinProposalTests.swift)
accept BIP 78's own vectors and refuse a dozen hostile proposals built by the
[test receiver](../../../Tests/Support/FakePayjoinReceiver.swift);
[sender tests](../../../Tests/WalletCoreTests/PayjoinSenderTests.swift) run
the session over loopback against the
[test directory](../../../Tests/Support/P2P/FakePayjoinDirectory.swift);
[the app flow](../../../AppTests/PayjoinSendFlowTests.swift) pays a request
end to end, and the [signet journey](../../../UITests/README.md) has Core
mine the result.
