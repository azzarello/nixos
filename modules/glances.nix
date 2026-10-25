# Glances: lightweight "what is the box doing right now" web dashboard, no accounts (Grafana/Prometheus
# keep the long-term history). Replaced Netdata (2026-10-25): Netdata v2's bundled UI pushes a
# Netdata Cloud sign-in on unclaimed agents. LAN/Tailscale only.
#
# Glances can't see containerd, so k3s shows up as an AMP panel: a root loop writes a pod summary
# (not-ready pods, top pods by memory, ZFS ARC) to /run/k3s-glance/summary.txt and Glances cats it.
# Glances itself stays a DynamicUser with no cluster credentials.
{ config, lib, pkgs, ... }:
let
  cfg = config.monitoring.glances;
  summary = "/run/k3s-glance/summary.txt";
  conf = pkgs.writeText "glances.conf" ''
    [global]
    check_update=false

    [outputs]
    # same-origin web UI only; reject Host headers it isn't served under (DNS rebinding)
    cors_origins=http://localhost:61208
    webui_allowed_hosts=${lib.concatStringsSep "," ([ "localhost" "127.0.0.1" config.networking.hostName ] ++ cfg.allowedHosts)}

    [network]
    hide=lo,veth.*,cni0,flannel.*

    [diskio]
    hide=loop.*,zd.*,ram.*

    [fs]
    hide=/boot.*,/nix/store,/run.*,/var/lib/kubelet.*,/var/lib/rancher.*

    [containers]
    disable=True

    [amps]
    disable=False

    [amp_k3s]
    enable=true
    regex=.*k3s server.*
    refresh=15
    one_line=false
    command=cat ${summary}
  '';
in {
  options.monitoring.glances = {
    enable = lib.mkEnableOption "Glances dashboard";
    interfaces = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Interfaces allowed to reach :61208 (e.g. the LAN NIC and tailscale0).";
    };
    allowedHosts = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra Host headers the web UI answers to: LAN IP, reverse-proxy hostname.";
    };
  };
  config = lib.mkIf cfg.enable {
    services.glances = {
      enable = true;
      extraArgs = [ "--webserver" "-C" "${conf}" ];
    };

    systemd.services.k3s-glance = lib.mkIf config.services.k3s.enable {
      description = "k3s pod summary for the Glances AMP panel";
      after = [ "k3s.service" ];
      wantedBy = [ "multi-user.target" ];
      environment.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
      path = with pkgs; [ kubectl gawk coreutils ];
      serviceConfig = { RuntimeDirectory = "k3s-glance"; RuntimeDirectoryMode = "0755"; Restart = "always"; };
      script = ''
        out=${summary}
        while :; do
          {
            awk '$1=="size" {printf "ZFS ARC %.1fG (counted as used memory above; yields to apps)\n", $3/2^30}' \
              /proc/spl/kstat/zfs/arcstats 2>/dev/null
            kubectl get pods -A --no-headers | awk '
              { n++; split($3, r, "/")
                if (($4 != "Running" && $4 != "Completed") || ($4 == "Running" && r[1] != r[2])) {
                  bad++; list = list sprintf("  %s/%s %s %s restarts=%s\n", $1, $2, $3, $4, $5) } }
              END { printf "pods %d, not ready %d\n%s", n, bad, list }'
            echo "top pods by memory (cpu, mem):"
            kubectl top pods -A --no-headers --sort-by=memory | head -12 | awk '
              { name = $2; sub(/-[a-z0-9]{8,10}-[a-z0-9]{5}$/, "", name); sub(/-[a-z0-9]{5}$/, "", name)
                printf "  %-11s %-28s %6s %8s\n", $1, substr(name, 1, 28), $3, $4 }'
          } > "$out.tmp" 2>&1 && mv "$out.tmp" "$out"
          sleep 15
        done
      '';
    };

    networking.firewall.interfaces = lib.genAttrs cfg.interfaces (_: { allowedTCPPorts = [ 61208 ]; });
  };
}
