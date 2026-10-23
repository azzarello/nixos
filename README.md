# nixos

NixOS configurations for my machines. Flake-based, tracking `nixos-unstable`.

| Host | Hardware | Role |
|------|----------|------|
| `breaker` | HP ProDesk 600 G6 Mini (i5-10500T, 64GB) | Always-on box — future router/DNS. SATA SSD boot (btrfs via disko), NVMe ZFS pool `pantry`. |

Rebuild on the host:

```sh
sudo nixos-rebuild switch --flake ~/nixos#breaker
```
