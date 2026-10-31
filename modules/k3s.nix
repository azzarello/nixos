# Single-node k3s (one independent cluster per host). App state lives under
# k3s.storagePath (breaker: the ZFS pool), the k3s data dir (images, containerd) stays on the boot disk.
{ config, lib, pkgs, ... }:
{
  options.k3s.storagePath = lib.mkOption {
    type = lib.types.str;
    default = "/var/lib/k3s-storage";
    description = "Default local-path provisioner directory (app PVCs).";
  };

  options.k3s.podNameservers = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    example = [ "192.168.1.1" ];
    description = ''
      Nameservers for pods (and CoreDNS's upstreams) instead of the host's. Set it when the host
      resolves through a loopback address (e.g. its own DNS server on 127.0.0.1), which pods can't use.
    '';
  };

  config = {
  services.k3s = {
    enable = true;
    role = "server";
    extraFlags = [
      "--write-kubeconfig-mode=0640"
      "--write-kubeconfig-group=wheel"
      "--default-local-storage-path=${config.k3s.storagePath}"
      "--tls-san=${config.networking.hostName}"
      # The host runs its own edge Traefik (hostNetwork :80/:443, sees real client IPs); the
      # bundled one's ServiceLB would DNAT 80/443 away from it.
      "--disable=traefik"
      "--resolv-conf=/run/k3s/resolv.conf"
    ];
  };

  # Pods (and CoreDNS's upstreams) get the host's nameservers but NOT its search domains. With
  # Tailscale's "search <tailnet>.ts.net" inherited, ndots:5 sent every external lookup out as
  # <name>.<tailnet>.ts.net first; public DNS answers that sometimes NOERROR-with-no-records
  # instead of NXDOMAIN, and musl (Alpine images) stops there: getaddrinfo fails for a real
  # name (2026-10-28: an app's metadata API lookups failed with ENOTFOUND).
  # Regenerated on every k3s start; pods take it when they're (re)created. A host whose resolver is
  # loopback-only (a router running its own DNS) sets k3s.podNameservers instead.
  systemd.services.k3s.preStart = if config.k3s.podNameservers != [ ] then ''
    mkdir -p /run/k3s
    printf 'nameserver %s\n' ${lib.escapeShellArgs config.k3s.podNameservers} > /run/k3s/resolv.conf
  '' else ''
    mkdir -p /run/k3s
    src=/run/systemd/resolve/resolv.conf; [ -s "$src" ] || src=/etc/resolv.conf
    ${pkgs.gnugrep}/bin/grep -E '^(nameserver|options)' "$src" | ${pkgs.gnugrep}/bin/grep -vE '^nameserver (127\.|::1)' > /run/k3s/resolv.conf.new || true
    ${pkgs.gnugrep}/bin/grep -q '^nameserver' /run/k3s/resolv.conf.new || echo 'nameserver 1.1.1.1' >> /run/k3s/resolv.conf.new
    mv /run/k3s/resolv.conf.new /run/k3s/resolv.conf
  '';

  # API server for kubectl from the LAN / tailnet; pod + overlay traffic is trusted.
  networking.firewall.allowedTCPPorts = [ 6443 ];
  networking.firewall.trustedInterfaces = [ "cni0" "flannel.1" ];

  # FUSE mounts inside pods (e.g. rclone) need allow_other on the host side too.
  programs.fuse.userAllowOther = true;

  # k3s runs with KillMode=process (so `systemctl restart k3s` keeps pods running), which
  # also means stopping it leaves every container + containerd-shim behind (29 on
  # 2026-10-23). systemd's final shutdown stage then waits ~90 s on them: a reboot took
  # ~3.7 min, of which the OS boot was 44 s.
  # This unit is ordered After=k3s, so at shutdown it stops FIRST, while containerd still
  # runs: SIGTERM every container (30 s grace, then SIGKILL; FUSE-mounting apps unmount on
  # TERM), then stop the pod sandboxes so the shims exit. kubelet recreates everything on
  # boot. (k3s-killall.sh isn't used: it `systemctl stop`s every k3s*.service, including
  # this one, and deadlocked until timeout.) Never restarted on switch: that would kill pods.
  systemd.services.k3s-stop-pods-on-shutdown = {
    description = "Gracefully stop all k3s containers at shutdown";
    wantedBy = [ "multi-user.target" ];
    after = [ "k3s.service" ];
    restartIfChanged = false;
    stopIfChanged = false;
    path = [ config.services.k3s.package pkgs.coreutils ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.coreutils}/bin/true";
      TimeoutStopSec = 100;
    };
    preStop = ''
      ids=$(k3s crictl ps -q 2>/dev/null)
      [ -n "$ids" ] && k3s crictl stop --timeout 30 $ids >/dev/null 2>&1
      pods=$(k3s crictl pods -q 2>/dev/null)
      [ -n "$pods" ] && k3s crictl stopp $pods >/dev/null 2>&1
      echo "stopped $(echo $ids | wc -w) containers, $(echo $pods | wc -w) pod sandboxes"
    '';
  };

  environment.variables.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
  environment.systemPackages = with pkgs; [ kubectl kubernetes-helm k9s ];
  };
}
