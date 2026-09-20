# Tailscale gateway discovery POC

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
protocol, not the operator or overlay type. This POC supports conventional
IPv4 tailnet addresses; custom address ranges and IPv6-only discovery need an
extension. Manual gateways support DNS names and bracketed IPv6 addresses.

Automatic always keeps clearnet eligible and adds each available overlay.
It is a resilience mode, not a promise of anonymous traffic. Selected networks
are eligible; the pool does not guarantee a slot on every network. Existing
peer provenance and address diversity checks remain in force. Gateways see
the destinations clients ask them to reach; Bitcoin peers still undergo the
normal version, compact-filter, header and chain checks.

Advanced Settings → Peer networks offers:

- **Automatic**: discover the conventional gateways and allow clearnet.
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
selected, SOCKS through Tor otherwise, and are disabled for I2P-only routing.
Preload the signed census before selecting I2P alone, or add I2P peers manually.
Corrupt saved routing settings keep networking offline until replaced.

## Validation

`swift test --filter 'PeerGatewayTests|TailnetGatewayDiscoveryTests'` checks
route isolation, candidate filtering, DNS parsing, SOCKS checks and cancellation.
The app tests cover persistence, corrupt preferences and stale discovery after
backgrounding or a settings change. `PeerGatewaySettingsUITests` exercises the
Advanced controls and relaunch persistence with a disposable wallet.

To opt into a read-only check of the two named gateways on the connected tailnet:

```sh
WINNOW_LIVE_GATEWAYS=1 swift test --filter TailnetGatewayDiscoveryTests.deployedMagicDNSGateways
```

Set `WINNOW_LIVE_CENSUS` to a current local `peers.json` file with its
`peers.json.sig` beside it to additionally verify the publisher signature and
perform Bitcoin handshakes through both discovered gateways. The check sends
no wallet addresses or transactions.

A successful greeting is not proof of Tor/I2P reachability. A physical iPhone
with the Tailscale VPN enabled remains part of device acceptance testing.
