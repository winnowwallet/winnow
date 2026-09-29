# Tor and I2P through Tailscale gateways

Fresh installations use **Automatic** routing in both simple and advanced mode.
Winnow checks `winnow-tor-gateway:9050` and `winnow-i2p-gateway:4447` when
networking starts in the foreground and when the user reconnects or retries.
Connect the Tailscale app to the intended tailnet first, with MagicDNS enabled.

Discovery asks Tailscale's Quad100 resolver (`100.100.100.100:53`) for these
two names directly. It accepts only IPv4 addresses in Tailscale's `100.64.0.0/10`
range and an unauthenticated SOCKS5 greeting. There is no public DNS fallback,
subnet scan, tailnet API token, embedded router, or additional Tailscale login.
Both lookups run concurrently; each DNS exchange and SOCKS check has a two-second
deadline and is cancelled when networking stops. Addresses are pinned for that
foreground networking generation, never saved to preferences. Discovery does
not monitor Tailscale continuously; reconnect or foreground Winnow after a change.

This is discovery by **name convention**, not by tag. The deployed servers have
`tag:winnow-tor` and `tag:winnow-i2p` for administration, but iOS does not consult
those tags. A tailnet administrator must reserve these names for trusted
gateways and allow access to their SOCKS ports. A SOCKS greeting identifies the
protocol, not the operator or overlay type. Discovery supports conventional
IPv4 tailnet addresses; custom address ranges and IPv6-only discovery need an
extension. Manual gateways support DNS names and bracketed IPv6 addresses.

When either gateway answers, Automatic uses only Tor and I2P: no peer
connection, catalog download or explorer lookup goes direct, and peers never
see the phone's IP address. When neither answers, it falls back to clearnet
so the wallet keeps syncing, and simple mode's banner says peers can see the
IP address. Existing peer provenance and address diversity checks remain in
force. Onion and I2P names have no address block to limit, so while clearnet
is selected automatic Tor and I2P peers together may not take every slot, and
with Tor and I2P both selected and clearnet off neither overlay may; a round
that cannot fill the pool with a mix relaxes that rule for the next one. Gateways see
the destinations clients ask them to reach; Bitcoin peers still undergo the
normal version, compact-filter, header and chain checks.

Advanced Settings → Peer networks offers:

- **Automatic**: discover the conventional gateways; use only them when
  either answers, clearnet when neither does.
- **Direct only**: skip discovery and use clearnet peers.
- **Manual**: choose any nonempty combination of clearnet, Tor and I2P and
  supply each selected overlay's SOCKS address. Edits take effect on **Apply
  routing**; these preferences remain active when returning to simple mode.

Tor and I2P destinations are sent by name to their respective SOCKS gateway;
failed overlay connections never dial those destinations directly. Manual,
persisted, signed-census and seed candidates all obey the selection. The signed
census now retains validated v3 onion and ordinary base32 I2P entries. It still
requires the existing publisher signature, freshness and clearnet diversity
checks. No overlay candidates are bundled.

Peer-list downloads and explorer requests use direct HTTP when clearnet is
selected and SOCKS through Tor otherwise. I2P-only routing fetches the signed
census from its I2P mirror through the I2P gateway and refuses every public
host, so explorer requests stay off. The census signature is checked as usual;
the mirror is not trusted. The mirror runs on the I2P gateway, copies the
signed files from the public census every 30 minutes, and serves them at
`CensusCatalog.i2pMirror`.
Corrupt saved routing settings keep networking offline until replaced.

The project's gateway VMs, including the I2P census mirror, are reproducible
from [winnowwallet/census `gateways/`](https://github.com/winnowwallet/census/tree/main/gateways).

## Validation

`swift test --filter 'PeerGatewayTests|TailnetGatewayDiscoveryTests'` checks
route isolation, candidate filtering, DNS parsing, SOCKS checks and cancellation.
The app tests cover persistence, corrupt preferences and stale discovery after
backgrounding or a settings change. `PeerGatewaySettingsUITests` exercises the
Advanced controls and relaunch persistence with a disposable wallet.

To opt into a read-only check of the two named gateways on the connected tailnet:

```sh
scripts/check-live-gateways [peers.json]
```

It discovers both gateways, then fetches the census from its I2P mirror through
the I2P gateway and verifies the publisher signature. Given a current local
`peers.json` with its `peers.json.sig` beside it, it also performs Bitcoin
handshakes through both gateways. The check sends no wallet addresses or
transactions. CI has no tailnet, so this check is manual; the
[2026-09-29 run](security/evidence/live-gateways-2026-09-29.md) is recorded.

A successful greeting is not proof of Tor/I2P reachability. A physical iPhone
with the Tailscale VPN enabled remains part of device acceptance testing.
