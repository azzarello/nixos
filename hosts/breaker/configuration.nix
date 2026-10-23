{ lib, pkgs, ... }:
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
  zfs.datasets."pantry/k3s" = { mountpoint = "/pantry/k3s"; };   # k3s app state (hostPath dirs)

  # k3s hostPath volumes live on pantry: never start the cluster before the dataset is there.
  systemd.services.k3s = {
    after = [ "zfs-datasets.service" ];
    requires = [ "zfs-datasets.service" ];
    unitConfig.RequiresMountsFor = [ "/pantry/k3s" ];
  };

  # fridge (Unraid NAS) exports its media + downloads shares to breaker only (NFS, rw).
  # On-demand automount + nofail: breaker boots and runs fine while fridge is down.
  # Nothing uses these until the stream-tier cutover (local tier on fridge's disks).
  fileSystems = lib.genAttrs [ "/mnt/fridge/media" "/mnt/fridge/downloads" ] (mnt: {
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
  networking.interfaces.eno1.useDHCP = true;
  systemd.network.wait-online.anyInterface = true;
  networking.firewall.enable = true;

  time.timeZone = "America/Los_Angeles";
  i18n.defaultLocale = "en_US.UTF-8";

  users.users.corndog = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOuPPXrbNYSI9VidTM20hFZOhL/4SklO++MjNbh0WpsZ corndog@mac"
    ];
  };

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  services.tailscale.enable = true;
  services.fstrim.enable = true;
  hardware.enableRedistributableFirmware = true;

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    trusted-users = [ "@wheel" ];
    # a hung cache download once stalled a rebuild for 10+ min; fail fast and retry instead
    connect-timeout = 10;
    stalled-download-timeout = 60;
  };
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  environment.systemPackages = with pkgs; [
    git vim htop btop curl dig tcpdump ethtool pciutils usbutils smartmontools rsync nfs-utils
  ];

  system.stateVersion = "26.05";
}
