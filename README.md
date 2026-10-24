# nixos

NixOS configurations for my machines. Flake-based, tracking `nixos-unstable`.

| Host | Hardware | Role |
|------|----------|------|
| `breaker` | HP ProDesk 600 G6 Mini (i5-10500T, 64GB) | Always-on box: k3s, ZFS pool `pantry`; staged to become the home router |

## Layout
| Path | What |
|---|---|
| `hosts/breaker/` | host config, disko layout (SATA SSD, btrfs), generated hardware config |
| `modules/k3s.nix` | single-node k3s; app state on ZFS; graceful pod stop at shutdown |
| `modules/zfs-datasets.nix` | declarative ZFS datasets (create + converge properties, never destroy) |
| `modules/router.nix` | router role (WAN DHCP, NAT, Kea DHCP, AdGuard Home DNS, WAN-closed firewall), off by default |
| `tests/router.nix` | VM test: fake ISP <-> router <-> LAN client |
| `docs/router.md` | router design + cutover/rollback runbook |

## Usage
```sh
sudo nixos-rebuild switch --flake ~/nixos#breaker          # on the host
nix build .#checks.x86_64-linux.router                     # router VM test (needs KVM)
nix build .#checks.x86_64-linux.breaker-router             # cutover config builds
```
