# Single-node k3s. App state lives on the ZFS pool (hostPath dirs under /pantry/k3s),
# the k3s data dir (images, containerd) stays on the boot SSD.
{ config, pkgs, ... }:
{
  services.k3s = {
    enable = true;
    role = "server";
    extraFlags = [
      "--write-kubeconfig-mode=0640"
      "--write-kubeconfig-group=wheel"
      "--default-local-storage-path=/pantry/k3s/local-path"
      "--tls-san=breaker"
    ];
  };

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
}
