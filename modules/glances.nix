# Glances: lightweight "what is the box doing right now" web dashboard, no accounts (Grafana/Prometheus
# keep the long-term history). Replaced Netdata (2026-10-25): Netdata v2's bundled UI pushes a
# Netdata Cloud sign-in on unclaimed agents. LAN/Tailscale only.
#
# Glances can't see containerd, so k3s shows up as an AMP panel: a root loop writes a pod summary
# (not-ready pods, top pods by memory, ZFS ARC, RAPL power) to /run/k3s-glance/summary.txt and Glances cats it.
# Glances itself stays a DynamicUser with no cluster credentials.
#
# Intel iGPU (monitoring.glances.intelGpu): Glances' own GPU plugin reports clock / max clock as "proc %" (about 30%
# at idle on a 350-1150 MHz part), not load. gpu-glance.service samples intel_gpu_top instead (busy % per engine,
# GPU watts, the processes using it) and Glances shows that as the "Gpu" AMP panel.
#
# Phones: glances-mobile.html is added to Glances' own /static (same origin as its API) and served at
# /static/m.html; the stock UI hides disks/network/sensors below 768 px. The reverse proxy can send
# phone user agents from / to it (full UI stays at /?full=1).
{ config, lib, pkgs, ... }:
let
  cfg = config.monitoring.glances;
  summary = "/run/k3s-glance/summary.txt";
  driveTemps = "/run/drive-temps/temps.txt";
  gpuSummary = "/run/gpu-glance/gpu.txt";
  conf = pkgs.writeText "glances.conf" (''
    [global]
    # 10 s, not the default 2 s: an open web page made Glances poll everything every 2 s (~200m CPU, ~2 W on breaker, 2026-11-18)
    refresh=10
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

    # NVMe/SATA temperatures come from the Drives panel below (named by model, with the drive's own
    # limits). The raw hwmon labels (Composite, Composite 1, Sensor 2 3) don't say which drive is which,
    # and nvme0/nvme1 swap order between boots.
    [sensors]
    hide=composite.*,sensor .*,drivetemp.*
    alias=package id 0:CPU package,core 0:CPU core 0,core 1:CPU core 1,core 2:CPU core 2,core 3:CPU core 3,core 4:CPU core 4,core 5:CPU core 5,pch_cometlake 0:Chipset

    [containers]
    disable=True

    [amps]
    disable=False

    [amp_drives]
    enable=true
    regex=.*glances.*
    refresh=15
    one_line=false
    command=cat ${driveTemps}

    [amp_k3s]
    enable=true
    regex=.*k3s server.*
    refresh=15
    one_line=false
    command=cat ${summary}
  '' + lib.optionalString cfg.intelGpu ''

    [amp_gpu]
    enable=true
    regex=.*glances.*
    refresh=15
    one_line=false
    command=cat ${gpuSummary}
  '');
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
    intelGpu = lib.mkEnableOption "the Intel iGPU panel (gpu-glance.service samples intel_gpu_top as root every 15 s)";
  };
  config = lib.mkIf cfg.enable {
    services.glances = {
      enable = true;
      package = pkgs.glances.overridePythonAttrs (old: {
        postInstall = (old.postInstall or "") + ''
          install -m644 ${./glances-mobile.html} "$(echo $out/lib/python*/site-packages/glances/outputs/static/public)/m.html"
        '';
        doCheck = false;   # only a static file added; upstream's tests already ran on the base package
        # python-jose is optional in Glances (only for JWT login on the web API, unused: no password here) and nixpkgs
        # marks 3.5.0 insecure (CVE-2026-120459): leave it out rather than permit an insecure package
        dependencies = lib.filter (d: (d.pname or "") != "python-jose") old.dependencies;
        pythonRemoveDeps = (old.pythonRemoveDeps or [ ]) ++ [ "python-jose" ];
      });
      # 10 s, not the default 2 s: an open web page made Glances poll everything every 2 s (~200m CPU, ~2 W on breaker, 2026-11-18)
      extraArgs = [ "--webserver" "-C" "${conf}" "-t" "10" ];
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
        cores=$(nproc)
        # RAPL energy counters (root-only since CVE-2020-8694): psys = platform/board, package-0 = CPU+iGPU.
        # Watts = energy delta over the loop interval; counters wrap at max_energy_range_uj.
        # sets $W (not echoed: a $(...) subshell would lose last[] between calls)
        declare -A last
        watts() {
          local d=/sys/class/powercap/$1 e r; W=""
          [ -r "$d/energy_uj" ] || return 0
          e=$(cat "$d/energy_uj"); r=$(cat "$d/max_energy_range_uj")
          if [ -n "''${last[$1]:-}" ]; then
            local de=$(( e - ''${last[$1]%:*} )) dt=$(( $(date +%s%N) - ''${last[$1]#*:} ))
            (( de < 0 )) && de=$(( de + r ))
            W=$(awk -v de="$de" -v dt="$dt" 'BEGIN { printf "%.1f", de * 1000 / dt }')
          fi
          last[$1]="$e:$(date +%s%N)"
        }
        while :; do
          watts intel-rapl:1; psys=$W; watts intel-rapl:0; pkg=$W
          {
            [ -n "$psys$pkg" ] && echo "power ''${psys:-?} W platform, ''${pkg:-?} W CPU package (RAPL; wall is a bit higher)"
            awk '$1=="size" {printf "ZFS ARC %.1fG (in cache, not used memory)\n", $3/2^30}' \
              /proc/spl/kstat/zfs/arcstats 2>/dev/null
            kubectl get pods -A --no-headers | awk '
              { n++; split($3, r, "/")
                if (($4 != "Running" && $4 != "Completed") || ($4 == "Running" && r[1] != r[2])) {
                  bad++; list = list sprintf("  %s/%s %s %s restarts=%s\n", $1, $2, $3, $4, $5) } }
              END { printf "pods %d, not ready %d\n%s", n, bad, list }'
            # kubectl reports millicores (1000m = one thread): shown as % of the whole box, like the CPU total
            echo "top pods by memory (cpu % of $cores threads, mem):"
            kubectl top pods -A --no-headers --sort-by=memory | head -12 | awk -v cores="$cores" '
              { name = $2; sub(/-[a-z0-9]{8,10}-[a-z0-9]{5}$/, "", name); sub(/-[a-z0-9]{5}$/, "", name)
                cpu = $3; sub(/m$/, "", cpu); mem = $4; sub(/Mi$/, "", mem)
                printf "  %-11s %-28s %5.1f%% %5.1fG\n", $1, substr(name, 1, 28), cpu / (cores * 10), mem / 1024 }'
          } > "$out.tmp" 2>&1 && mv "$out.tmp" "$out"
          sleep 15
        done
      '';
    };

    # Drive temperatures by model: "<model>  <composite>C  sensor2 <n>C  limit <warn>/<crit>". sysfs hwmon
    # files are world-readable, so this needs no privileges. sensor2 is the controller on NVMe drives.
    systemd.services.drive-temps = {
      description = "Drive temperatures for the Glances Drives panel";
      wantedBy = [ "multi-user.target" ];
      path = with pkgs; [ coreutils gnused ];
      serviceConfig = { DynamicUser = true; RuntimeDirectory = "drive-temps"; RuntimeDirectoryMode = "0755"; Restart = "always"; };
      script = ''
        while :; do
          for h in /sys/class/hwmon/hwmon*; do
            n=$(cat "$h/name" 2>/dev/null)
            case "$n" in nvme|drivetemp) ;; *) continue ;; esac
            m=$(tr -s ' ' < "$h/device/model" 2>/dev/null | sed 's/ *$//'); [ -n "$m" ] || m=$n
            read -r c < "$h/temp1_input" || continue
            l="$m  $((c/1000))°C"
            [ -r "$h/temp3_input" ] && l="$l  sensor2 $(( $(cat "$h/temp3_input")/1000 ))°C"
            w=$(cat "$h/temp1_max" 2>/dev/null) k=$(cat "$h/temp1_crit" 2>/dev/null)
            [ -n "$w" ] && [ -n "$k" ] && l="$l  limit $((w/1000))/$((k/1000))"
            echo "$l"
          done | sort > ${driveTemps}.tmp && mv ${driveTemps}.tmp ${driveTemps}
          sleep 15
        done
      '';
    };

    # Intel iGPU panel: "engines render 10.8%  blitter 0%  video 1.4%  enhance 0%", "awake 21%  clock 149 MHz  power
    # 1.3 W", then "client <pod or host> <process>  render 9.7%" for each process using the GPU right now. One 1 s
    # sample every 15 s (~0.14 s CPU each). Root: the i915 PMU needs CAP_PERFMON, per-process use comes from other
    # users' /proc/<pid>/fdinfo, and a container's pod name from /proc/<pid>/root/etc/hostname. clock is the average
    # over the sample, idle (RC6) time included. No i915 (the VM tests): no sample, so the panel stays empty.
    systemd.services.gpu-glance = lib.mkIf cfg.intelGpu {
      description = "Intel GPU summary for the Glances Gpu panel";
      wantedBy = [ "multi-user.target" ];
      path = with pkgs; [ intel-gpu-tools jq gnused coreutils ];
      serviceConfig = { RuntimeDirectory = "gpu-glance"; RuntimeDirectoryMode = "0755"; Restart = "always"; };
      script = ''
        out=${gpuSummary}
        while :; do
          j=$(intel_gpu_top -J -s 1000 -n 2 2>/dev/null | jq -c '.[-1]' 2>/dev/null) || j=""
          if [ -n "$j" ] && [ "$j" != null ]; then
            jq -r '
              def pct: (tonumber * 10 | round / 10 | tostring) + "%";
              def eng: ascii_downcase | sub("/3d$"; "") | sub("videoenhance"; "enhance");
              "engines " + ([.engines | to_entries[] | "\(.key | eng) \(.value.busy | pct)"] | join("  ")),
              "awake \(100 - .rc6.value | round)%  clock \(.frequency.actual | round) MHz  power \((.power.GPU // 0) * 10 | round / 10) W",
              (.clients // {} | .[] | select([.["engine-classes"][].busy | tonumber] | max > 0)
                | "client \(.pid) \(.name)  " + ([.["engine-classes"] | to_entries[] | select((.value.busy | tonumber) > 0)
                    | "\(.key | eng) \(.value.busy | pct)"] | join("  ")))
            ' <<<"$j" | while IFS= read -r l; do
              case $l in
                "client "*)
                  rest=''${l#client }; pid=''${rest%% *}; rest=''${rest#* }
                  # pod name without its ReplicaSet/pod hash (as in the K3s panel); the host's name for host processes
                  who=$(sed -E 's/-[a-z0-9]{8,10}-[a-z0-9]{5}$//; s/-[a-z0-9]{5}$//' "/proc/$pid/root/etc/hostname" 2>/dev/null) || who="?"
                  echo "client ''${who:-?} $rest" ;;
                *) echo "$l" ;;
              esac
            done > "$out.tmp" && mv "$out.tmp" "$out"
          fi
          sleep 14
        done
      '';
    };

    networking.firewall.interfaces = lib.genAttrs cfg.interfaces (_: { allowedTCPPorts = [ 61208 ]; });
  };
}
