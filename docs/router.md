# breaker as the home router

Status: **staged, not live.** `modules/router.nix` is imported on breaker with
`router.enable = false`; `nixosConfigurations.breaker-router` is the same host with it on.
`nix build .#checks.x86_64-linux.router` runs the VM test (fake ISP ↔ router ↔ client).

## Topology after cutover

```
ISP modem ──(enp2s0, I225 2.5GbE, DHCP client)── breaker ──(eno1, I219, 192.168.68.1/22)── switch / Decos (AP mode) ── LAN
```

| Piece | Implementation | Notes |
|---|---|---|
| WAN | systemd-networkd DHCP on `enp2s0` | ISP DNS ignored (`UseDNS=false`) |
| LAN | static `192.168.68.1/22` on `eno1` | same subnet the Decos hand out today → no client changes |
| NAT | `networking.nat` (iptables MASQUERADE) | coexists with k3s's iptables rules |
| DHCP | Kea, pool `192.168.69.1–192.168.70.254`, 24h leases | reservations in `router.dhcp.reservations` (fridge = .67) |
| DNS | AdGuard Home on `127.0.0.1` + LAN IP, DoH upstreams (Quad9, Cloudflare) | `ratelimit: 0`; `<host>.lan` names from reservations, `router.lan` |
| Firewall | per-interface allow (LAN, tailscale0, k3s CNI): 22, 53, 80, 443, 6443, DHCP | **nothing** opened globally |
| WAN inbound | mangle/PREROUTING drop of every NEW connection on WAN | runs **before DNAT** (see below) |

### Why the WAN drop is in mangle/PREROUTING
k3s ServiceLB (and any `hostPort`) installs DNAT rules matching *every local address*.
DNATed traffic is forwarded to pods and never hits the INPUT chain, so a closed INPUT
firewall does **not** protect LoadBalancer ports. Without the mangle drop, every web UI
hosted in the cluster would be reachable on the WAN IP. The VM test reproduces exactly this
(a `--dst-type LOCAL` DNAT to a LAN host) and verifies that it's blocked, and that it's
reachable with the drop removed, which shows the test can actually catch the problem.

## Not in scope yet
- **IPv6**: no RA/DHCPv6 on the LAN, no v6 forwarding. LAN stays v4 (as with the Decos' current
  config). Add prefix delegation (networkd `DHCPPrefixDelegation`) later.
- Port forwards / public services: none yet.
- VLANs/guest network, QoS/SQM (cake), WireGuard: later modules.

## Addresses in router mode
breaker keeps **192.168.68.71** on eno1 next to the gateway address **.1**, with .71 listed first
(the primary address, so LAN traffic *from* breaker uses it). k3s is pinned to `--node-ip=.71`
(otherwise it takes the default route's interface: the WAN), AMT keeps .71 (same MAC), and anything
on the LAN that talks to breaker by IP keeps working. Pods resolve through AdGuard on the LAN address
(`k3s.podNameservers`), since the host's own resolver is 127.0.0.1.

## Cutover runbook
breaker is deployed from a private overlay flake that imports this one (GitOps: it builds and switches
its own config from git). **Cut over there**, by setting `router.enable = true` in the overlay. Never
`nixos-rebuild switch --flake .#breaker-router` from this repo on a host the overlay deploys: that drops
the overlay's services, and the deployer switches back to the overlay's config on its next run. The
overlay's own runbook has the exact steps; in outline:

Prereqs (days before):
1. **AMT static IP.** AMT shares eno1's MAC but its DHCP frames bypass the host, so breaker's
   Kea never sees them. In MEBx (Esc boot menu → ME setup) set AMT to static
   `192.168.68.71/22`, gateway `192.168.68.1`, DNS `192.168.68.1`. Verify
   `http://192.168.68.71:16992` still answers.
2. Export the Decos' DHCP reservations + port forwards (if any) and add the reservations to
   `router.dhcp.reservations`. Note devices with hardcoded DNS.
3. Decide on AdGuard filter lists/rules (the NAS's AdGuard config is the reference), and copy them in.
4. The router VM tests and the overlay's router-mode boot test: green.
5. Lower the Decos' DHCP lease time to ~1h the day before, so clients renew quickly.

Cutover (~15 min, someone at home; the house has no internet in between):
1. Put the Decos in **access point mode** (Deco app → Advanced → Operation Mode). The LAN
   briefly has no DHCP; existing leases keep working on the same subnet.
2. Cable: ISP modem → breaker `enp2s0`; breaker `eno1` → main Deco/switch.
3. Switch breaker to the router-mode config (the overlay's step, triggered on breaker over SSH to .71,
   which stays up). Power-cycle the modem if `enp2s0` gets no lease.
4. Verify: `networkctl status enp2s0` has a public/CGNAT IP; a phone gets a 192.168.69.x/70.x lease;
   `dig @192.168.68.1 example.com`; browsing works; the NAS is still .67.
5. Point the NAS's AdGuard role at breaker (or leave the NAS's AdGuard as a secondary).

Rollback: switch breaker back to its previous generation, recable the modem to the main Deco, and set
the Decos back to router mode. The overlay's runbook covers keeping its deployer from re-flipping it.
