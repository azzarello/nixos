# Single-node k3s. App state lives on the ZFS pool (hostPath dirs under /pantry/k3s),
# the k3s data dir (images, containerd) stays on the boot SSD.
{ pkgs, ... }:
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

  environment.variables.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
  environment.systemPackages = with pkgs; [ kubectl kubernetes-helm k9s ];
}
