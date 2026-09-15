# Winnow peer gateways on TDX

Two dedicated KVM VMs run Tor and i2pd. Each has two vCPUs, 1.5 GiB RAM,
a 12 GiB copy-on-write disk, and its own daemon state. QEMU runs as
`libvirt-qemu`, managed by two systemd services. These are ordinary KVM VMs
on the TDX host; this recipe does not enable confidential-guest attestation.

The existing host Tailscale identity exposes their SOCKS5 listeners:

| Network | Winnow gateway | Host loopback forwarding | Guest SSH via host |
| --- | --- | --- | --- |
| Tor | `100.112.65.68:9050` | `127.0.0.1:19050` → guest 9050 | 22051 |
| I2P | `100.112.65.68:4447` | `127.0.0.1:14447` → guest 4447 | 22052 |

`tdx2.degu-cliff.ts.net` can replace the IP. Tailscale Serve is tailnet-only;
there is no Funnel, public SOCKS listener, exit-node setting, or new subnet
route. The VMs use separate QEMU user-mode networks, leaving existing
libvirt networks and other VMs alone. Access follows the host's existing
Tailscale ACLs. Clients must have Tailscale connected. The host, as gateway
operator, is trusted with the proxy destinations.

## Reproduce

Host prerequisites: Linux x86-64, KVM, QEMU with user networking,
`qemu-img`, `genisoimage`, Python 3.11+, systemd, a `libvirt-qemu` user with
KVM access, and an already enrolled Tailscale host. TDX already has these.
On a new Ubuntu host, the VM tools come from `qemu-system-x86`, `qemu-utils`,
`genisoimage`, and `libvirt-daemon-system`.

Copy this directory and your **public** SSH key to the host. From the copied
directory, run:

```sh
sudo python3 provision.py /path/to/admin.pub
```

The recipe pins the Ubuntu cloud image by dated URL and SHA-256, apt to
Ubuntu's 2026-09-15 snapshot, and upstream i2pd 2.61.0 by release-asset hash.
Tor resolves to `0.4.9.11-0ubuntu0.24.04.1` from that snapshot. Both guests
record `dpkg-query -W` in `/var/lib/gateway-packages.txt`. Reproducibility means
the same software and configuration, with fresh machine and overlay identities.
Do not distribute existing Tor or I2P private state as a template.

Wait for cloud-init and daemon readiness (first boot usually takes a few
minutes). SSH from your workstation through the host:

```sh
ssh -J tdx2 -p 22051 gateway@127.0.0.1 'cloud-init status; systemctl is-active tor@default'
ssh -J tdx2 -p 22052 gateway@127.0.0.1 'cloud-init status; systemctl is-active i2pd'
```

Tor's journal should reach `Bootstrapped 100%`. I2P needs reseeding and tunnels
before it can reach a peer. `publish.py` checks both SOCKS greetings and
refuses to overwrite an unrelated Tailscale port configuration:

```sh
sudo python3 publish.py
sudo tailscale serve status
```

The configuration and disk live under `/var/lib/winnow-peer-gateways/`;
services are `winnow-tor-gateway` and `winnow-i2p-gateway`. Both services and
Tailscale Serve persist across host reboots. Provisioning is serialized and
idempotent. It does not restart a running VM or recreate an existing disk.
A changed cloud-init configuration is rejected rather than silently ignored
by an already booted guest. Review upgrades explicitly: update the pinned
inputs and apply the corresponding guest configuration, or build replacement
VMs with distinct paths, names, and ports. Cloud-init runs only on first boot.
Retain the verified base image when archiving a deployment: overlays depend
on it, and upstream download retention is outside this recipe's control.

## Winnow Advanced mode

1. Enable Advanced mode and open Settings → Peer networks.
2. Turn on **Use external gateways**, select any nonempty combination of
   **Clearnet peers**, **Tor peers**, and **I2P peers**, and enter the gateway
   addresses above for selected overlays.
3. Tap **Apply peer routing**. This cancels the old HTTP generation, disconnects
   the old peer pool, saves the configuration, and builds new connections.
4. Tap **Refresh peer list** to load current Tor and I2P candidates. For an
   I2P-only setup, refresh while Tor or clearnet is still selected, then switch
   to I2P only; alternatively add I2P peers manually. The bundled I2P fallback
   is currently empty. Downloaded catalogs expire after seven days.

Selections are eligibility rules, not a guarantee of one connected peer per
network. Manual, saved, catalog, fallback, and discovered peers all obey the
same selection. Clearnet peers connect directly. Tor and I2P names are passed
unresolved to their respective SOCKS gateway. A failed overlay never tries a
clearnet route. External mode never starts the embedded Tor runtime.

Census downloads and explicitly consented explorer requests use direct HTTP
when clearnet is selected, Tor otherwise when Tor is selected, and stay offline
in I2P-only mode. The selection persists across backgrounding and relaunch.
Disabling external mode restores the existing built-in Tor/direct preference.
No wallet data or gateway secrets are stored in this recipe.

## Verify and operate

`check-peer.py` checks SOCKS5, a checksummed Bitcoin mainnet version response,
and the compact-filter service bit. It sends no wallet addresses or transactions.
Supply a current peer from `https://census.winnowwallet.com/census/peers.json`:

```sh
python3 check-peer.py 100.112.65.68 9050 PEER.onion 8333
python3 check-peer.py 100.112.65.68 4447 PEER.b32.i2p 8333
```

A successful greeting alone does not establish overlay connectivity. Some
peers will be offline; try another current candidate. `proxy.i2p` also depends
on an address book; a census `.b32.i2p` peer avoids that dependency.

```sh
# Host
sudo systemctl status winnow-tor-gateway winnow-i2p-gateway
sudo tail /var/lib/winnow-peer-gateways/tor/console.log
sudo tail /var/lib/winnow-peer-gateways/i2p/console.log
# Guest daemon logs
ssh -J tdx2 -p 22051 gateway@127.0.0.1 'sudo journalctl -u tor@default -n 30'
ssh -J tdx2 -p 22052 gateway@127.0.0.1 'sudo tail /var/log/i2pd/i2pd.log'
```

To withdraw only these gateways, retaining their state:

```sh
sudo tailscale serve --tcp=9050 off
sudo tailscale serve --tcp=4447 off
sudo systemctl disable --now winnow-tor-gateway winnow-i2p-gateway
```

Do not use `tailscale serve reset`, which would remove other services too.
The recipe never edits another agent's checkout or existing VM definitions.

## Sources

- [Ubuntu cloud images](https://cloud-images.ubuntu.com/noble/)
- [Ubuntu snapshot service](https://snapshot.ubuntu.com/)
- [i2pd 2.61.0 release](https://github.com/PurpleI2P/i2pd/releases/tag/2.61.0)
- [i2pd configuration](https://docs.i2pd.website/en/latest/user-guide/configuration/)
- [Tailscale Serve](https://tailscale.com/docs/reference/tailscale-cli/serve)
