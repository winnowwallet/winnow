[Back to main README](../../../README.md)

# Satochip cosigner

A Satochip card running applet protocol 0.16 as one participant of a raw
MuSig2 account. The card implements BIP327 NonceGen and Sign only; this
directory computes what it needs from public session data and checks what it
returns. With the card's 2FA enabled, a separate checker approves each signing
context, so a compromised phone alone cannot get the card to sign. The design,
the APDU flow and its sources are in
[the design note](../../../docs/satochip-musig2.md).

`SatochipMuSig2.swift` encodes the 66-byte signing context the card's Sign
command takes and the checker's 22-byte approval of it. The BIP327 half lives
in [MuSig2.swift](../Descriptors/MuSig2.swift) as `partialSignParameters`.
