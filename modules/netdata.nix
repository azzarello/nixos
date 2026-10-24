# Netdata: per-second "what is the box doing right now" dashboard (Grafana/Prometheus keep the
# long-term history). Native service, not a pod, so it sees the whole host: cgroups (per k3s pod),
# ZFS + ARC, disks/SMART, NICs, sensors, systemd units. No Netdata Cloud; LAN/Tailscale only.
{ config, lib, pkgs, ... }:
let cfg = config.monitoring.netdata;
in {
  options.monitoring.netdata = {
    enable = lib.mkEnableOption "Netdata dashboard";
    interfaces = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Interfaces allowed to reach :19999 (e.g. the LAN NIC and tailscale0).";
    };
  };
  config = lib.mkIf cfg.enable {
    # The bundled dashboard ("cloud UI", works fully offline) is unfree in nixpkgs: allow just it.
    nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "netdata" ];
    services.netdata = {
      enable = true;
      package = pkgs.netdata.override { withCloudUi = true; };   # local dashboard UI, no cloud claim
      config = {
        global = { "memory mode" = "dbengine"; "update every" = 1; };
        db = { "dbengine multihost disk space MB" = 2048; };   # ~days of per-second history
        web = { "bind to" = "*"; };
        "plugin:cgroups" = { "enable by default cgroups names matching" = "*"; };
      };
    };
    # SMART + GPU collectors need these on the PATH
    systemd.services.netdata.path = with pkgs; [ smartmontools intel-gpu-tools nvme-cli ];
    networking.firewall.interfaces = lib.genAttrs cfg.interfaces (_: { allowedTCPPorts = [ 19999 ]; });
  };
}
