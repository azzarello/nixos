{ config, lib, pkgs, ... }:
{
  networking.hostName = "breaker";

  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 20;
  boot.loader.efi.canTouchEfiVariables = true;

  # ZFS for the NVMe data pool (created by hand after install, not by disko).
  # hostId is required by ZFS; stay on the default LTS kernel so unstable never outruns ZFS.
  boot.supportedFilesystems = [ "zfs" "nfs" ];
  boot.zfs.forceImportRoot = false;
  networking.hostId = "0dd18c00";
  services.zfs.autoScrub.enable = true;
  # pantry: SK hynix P31 1TB NVMe, single vdev for now. Add the second drive with:
  #   zpool attach pantry nvme-SHGP31-1000GM-2_AS12T000710902J21 /dev/disk/by-id/<new-nvme>
  boot.zfs.extraPools = [ "pantry" ];
  zfs.datasets."pantry" = { mountpoint = "/pantry"; properties."com.sun:auto-snapshot" = "false"; };
  # k3s app state (hostPath dirs). Auto-snapshotted: the undo button for every app's config/DBs.
  k3s.storagePath = "/pantry/k3s/local-path";
  zfs.datasets."pantry/k3s" = { mountpoint = "/pantry/k3s"; properties."com.sun:auto-snapshot" = "true"; };
  # Caches apps rewrite constantly (e.g. a streaming VFS cache): never snapshotted. Inside pantry/k3s
  # every evicted chunk stayed pinned by the 15-min/hourly/daily snapshots (300 GB, 2026-10-25).
  zfs.datasets."pantry/cache" = { mountpoint = "/pantry/cache"; properties."com.sun:auto-snapshot" = "false"; };
  services.zfs.autoSnapshot = {
    enable = true;
    flags = "-k -p --utc";   # keep zero-size snapshots, run in parallel, UTC names
    frequent = 4;            # 15-min, last hour
    hourly = 24;
    daily = 14;
    weekly = 4;
    monthly = 6;
  };

  # k3s hostPath volumes live on pantry: never start the cluster before the dataset is there.
  systemd.services.k3s = {
    after = [ "zfs-datasets.service" ];
    requires = [ "zfs-datasets.service" ];
    unitConfig.RequiresMountsFor = [ "/pantry/k3s" ];
  };

  # fridge (Unraid NAS) exports its media + downloads shares to breaker only (NFS, rw).
  # On-demand automount + nofail: breaker boots and runs fine while fridge is down.
  # Nothing uses these until the stream-tier cutover (local tier on fridge's disks).
  fileSystems = lib.genAttrs [ "/mnt/fridge/media" "/mnt/fridge/downloads" "/mnt/fridge/backups" ] (mnt: {
    device = "192.168.68.67:/mnt/user/${baseNameOf mnt}";
    fsType = "nfs";
    options = [ "nfsvers=4.2" "noauto" "nofail" "x-systemd.automount" "x-systemd.idle-timeout=600"
                "x-systemd.mount-timeout=30" "_netdev" "noatime" ];
  });

  # NICs: eno1 = onboard I219-LM (e1000e) — Intel AMT lives here, so it must only ever face the LAN.
  #       enp2s0 = I225 2.5GbE (igc) — the natural WAN port when this becomes the router.
  # Plain DHCP client for now. Router/DNS roles get their own modules later.
  networking.useNetworkd = true;
  networking.useDHCP = false;
  # DHCP client on eno1 until breaker becomes the router (then eno1 is the static LAN gateway).
  networking.interfaces.eno1.useDHCP = lib.mkIf (!config.router.enable) true;
  systemd.network.wait-online.anyInterface = true;

  # If breaker boots while an AMT SOL/IDE-R session holds the I219's PHY, e1000e can't
  # reset it ("PHY reset is blocked due to SOL/IDER session") and the link stays at
  # AMT's 10 Mb/s low-power rate. Seen 2026-10-23 (0.3 MB/s downloads). Renegotiate
  # until it's gigabit; harmless when it already is.
  systemd.services.eno1-gigabit = {
    description = "Renegotiate eno1 if it came up below 1000 Mb/s";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    path = [ pkgs.ethtool ];
    serviceConfig.Type = "oneshot";
    script = ''
      for try in 1 2 3; do
        speed=$(cat /sys/class/net/eno1/speed 2>/dev/null || echo 0)
        [ "$speed" -ge 1000 ] && { echo "eno1 at $speed Mb/s"; exit 0; }
        echo "eno1 at $speed Mb/s, renegotiating (try $try)"
        ethtool -r eno1; sleep 10
      done
      echo "eno1 still below gigabit after 3 tries" >&2; exit 1
    '';
  };
  networking.firewall.enable = true;
  # edge reverse proxy (Traefik, hostNetwork pod) for the LAN; WAN stays closed in router mode
  networking.firewall.allowedTCPPorts = [ 80 443 ];

  # Router role, staged but OFF. Cutover = `router.enable = true` (the breaker-router config
  # in flake.nix) + the runbook in docs/router.md. The LAN keeps today's Deco subnet so
  # nothing else on the network has to change; the Decos go to access-point mode.
  router = {
    wan = "enp2s0";          # I225 2.5GbE -> ISP modem
    lan = "eno1";            # I219 -> LAN switch/Decos (AMT lives here: LAN-only, never WAN)
    address = "192.168.68.1";
    prefixLength = 22;
    subnet = "192.168.68.0/22";
    dhcp.pool = "192.168.69.1 - 192.168.70.254";
    dhcp.reservations = [
      { mac = "fc:aa:14:97:9b:11"; ip = "192.168.68.67"; hostname = "fridge"; }
    ];
    # AMT (same MAC as eno1) can't get a lease from breaker's own Kea: its DHCP frames go
    # straight out the PHY, never through the host stack. Give AMT a static IP in MEBx
    # (192.168.68.71) BEFORE cutover — see docs/router.md.
    trustedInterfaces = [ "tailscale0" "cni0" "flannel.1" ];
    # Same blocklists/rules as the NAS's AdGuard today (rewrites + named clients are private).
    dns = {
      upstreams = [ "https://dns10.quad9.net/dns-query" "https://cloudflare-dns.com/dns-query" ];
      bootstrap = [ "9.9.9.10" "149.112.112.10" ];
      filters = [
        { name = "AdGuard DNS filter"; url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt"; }
        { name = "AdAway Default Blocklist"; url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_2.txt"; }
        { name = "Peter Lowe's List"; url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_3.txt"; }
        { name = "Hagezi DNS - Pro"; url = "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/pro.txt"; }
        { name = "OISD Big"; url = "https://big.oisd.nl"; }
      ];
      userRules = [ "||bytewlb.akadns.net^" "@@||msmetrics.ws.sonos.com^" ];
    };
  };

  # In router mode breaker KEEPS 192.168.68.71 as its own address, next to the gateway address
  # (.1): k3s's node IP, AMT (same MAC and IP), NFS exports on the NAS that allow .71, and every
  # config that names .71 keep working through the cutover (and an SSH session to .71 survives it).
  # .71 is listed first so it stays the primary address: LAN traffic FROM breaker uses it.
  networking.interfaces.eno1.ipv4.addresses = lib.mkIf config.router.enable (lib.mkBefore [
    { address = "192.168.68.71"; prefixLength = config.router.prefixLength; }
  ]);
  # Pin k3s to .71: by default it takes the default route's interface, which in router mode is the WAN.
  services.k3s.extraFlags = lib.mkIf config.router.enable [ "--node-ip=192.168.68.71" ];
  # breaker resolves via its own AdGuard on 127.0.0.1, which pods can't reach: give them the LAN address.
  k3s.podNameservers = lib.mkIf config.router.enable [ config.router.address ];

  services.tailscale = {
    enable = true;
    # breaker advertises the home LAN to the tailnet (approve in the Tailscale admin), so tailnet
    # devices reach LAN hosts directly instead of detouring through the NAS (found 2026-10-23: an
    # iPhone's video stream to breaker went phone -> NAS -> breaker even at home).
    useRoutingFeatures = "server";
    extraUpFlags = [ "--advertise-routes=192.168.68.0/22" ];
    extraSetFlags = [ "--advertise-routes=192.168.68.0/22" ];
  };
  monitoring.glances = { enable = true; interfaces = [ "eno1" "tailscale0" ]; };
  services.fstrim.enable = true;
  # Idle power (measured 2026-10-25 with turbostat SysWatt, 30 s windows): powertop's tunables (runtime PM for
  # idle PCI/SATA/USB devices, audio codec power save, NMI watchdog off, 15 s writeback) took the platform
  # from ~7.2 W to ~6.0-6.3 W and the package from PC2 into PC7/PC9 more often. EPP balance_power and
  # unloading Wi-Fi/BT were within noise (+-0.4 W), so left alone.
  powerManagement.powertop.enable = true;
  # ...except eno1 (I219-LM, e1000e): it carries AMT and has had link-speed trouble (eno1-gigabit below);
  # runtime PM saves nothing on a link that is always up.
  systemd.services.powertop.postStart = ''
    echo on > /sys/bus/pci/devices/0000:00:1f.6/power/control
  '';
  # SATA drive temperatures as hwmon sensors (node-exporter -> temp alerts / dashboards)
  boot.kernelModules = [ "drivetemp" ];
  hardware.enableRedistributableFirmware = true;

  environment.systemPackages = with pkgs; [
    git vim htop btop curl dig tcpdump ethtool pciutils usbutils smartmontools rsync nfs-utils
  ];

  system.stateVersion = "26.05";
}
