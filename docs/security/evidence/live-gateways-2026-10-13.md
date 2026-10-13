[Back to evidence README](README.md)

# Live Tor and I2P gateway check, 2026-10-13

A manual run from a Mac on the tailnet after the project's two
[peer gateways](../../peer-gateways.md) and the I2P census mirror moved from
the KVM VMs to an Umbrel home server, as the community app
[`ph4-winnow-gateways`](https://github.com/posix4e/ph4-umbrel/tree/main/ph4-winnow-gateways).
No wallet addresses or transactions were sent.

- **Revision:** main `57e59c4` (#213).
- **Census input:** `census/peers.json` dated 2026-10-12 from
  `census.winnowwallet.com`, SHA-256 `5a67c543dade09c7d3d2fcafcadb34a5581e2be707d0a2718eadb140ab8e9862`,
  with `peers.json.sig` SHA-256 `1762262862caf07f91389615f6415807c0523e1dfb4436e224423d4321ce9715`.
  It listed 949 clearnet, 2,843 Tor and 2,475 I2P endpoints.

## The move (13:43–13:59Z)

The Umbrel's two Tailscale containers joined beside the VMs, then the VMs'
machines were renamed `winnow-tor-gateway-old` and `winnow-i2p-gateway-old`
and the new ones given the canonical names. The I2P VM was stopped before the
mirror's destination key was copied to the Umbrel, so the destination was
never published from two routers; it answered through the I2P network about
seven minutes after the app restarted with the key. No wallet release was
needed: discovery is by name.

## Repository check (14:03Z)

```sh
scripts/check-live-gateways peers.json
```

| Step | Result |
|---|---|
| Discovery through `100.100.100.100` | `winnow-tor-gateway` → `100.110.238.104:9050`, `winnow-i2p-gateway` → `100.101.121.117:4447` |
| Census from the I2P mirror through the I2P gateway | 1,204,616 bytes, publisher signature verified |
| Bitcoin handshake through the Tor gateway | `/Satoshi:31.1.0/` |
| Bitcoin handshake through the I2P gateway | `/Satoshi:31.1.0/` |

`TailnetGatewayDiscoveryTests.deployedMagicDNSGateways` passed in 35.2
seconds. It also passed at 13:49Z, after the names moved and with the mirror
still on the VM, and at 14:00Z, after the mirror moved.

## Independent cross-checks (13:43–14:07Z)

These used ordinary tools rather than WalletCore:

- Both gateways answered an unauthenticated SOCKS5 greeting (`05 00`).
- Through the Tor gateway, `https://check.torproject.org/api/ip` reported
  `"IsTor":true`.
- `curl --socks5-hostname` through the I2P gateway fetched the mirror's
  `peers.json` in 15.3 seconds and `peers.json.sig` matching the public file
  above.
- census `gateways/check-peer.py` sent a Bitcoin `version` message through each
  gateway to six randomly chosen Tor and six I2P census endpoints. Every answer
  was a mainnet `version` with protocol 70016 and `NODE_COMPACT_FILTERS`.

| Network | Answered | Time |
|---|---|---|
| Tor | 5 / 6 (one timed out at 65 seconds) | 3.5–57.4 seconds |
| I2P | 6 / 6 | 2.8–12.9 seconds |

Ten fetches of `peers.json.sig` through each gateway, before and after:

| Through | Tor, from census.winnowwallet.com | I2P, from the mirror |
|---|---|---|
| The VMs (13:03Z) | median 1.32 s, 1.16–3.34 s | median 2.49 s, 2.38–30.31 s (first) |
| The Umbrel (14:01Z) | median 1.30 s, 1.06–3.06 s | median 2.08 s, 2.00–2.23 s |

A successful handshake shows reachability through the gateways at that time;
it says nothing about the operators' independence or honesty, which the
wallet's header and filter checks still decide.
