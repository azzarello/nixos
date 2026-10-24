# VM test for modules/router.nix:  isp (fake upstream) <-vlan1-> router <-vlan2-> client
#   nix build .#checks.x86_64-linux.router        (needs KVM; run it on breaker)
#   nix build .#checks.x86_64-linux.router-k3s    (+ real k3s/ServiceLB on the router, heavier)
{ pkgs, withK3s ? false, ... }:
let
  # A LoadBalancer Service the way the real apps are exposed (k3s ServiceLB / klipper-lb).
  webManifest = pkgs.writeText "web.yaml" ''
    apiVersion: apps/v1
    kind: Deployment
    metadata: {name: web}
    spec:
      selector: {matchLabels: {app: web}}
      template:
        metadata: {labels: {app: web}}
        spec:
          containers:
            - name: web
              image: rancher/mirrored-library-busybox:1.37.0
              imagePullPolicy: Never
              command: [sh, -c, "echo hello-from-pod > /tmp/index.html && exec httpd -f -p 8080 -h /tmp"]
    ---
    apiVersion: v1
    kind: Service
    metadata: {name: web}
    spec:
      type: LoadBalancer
      selector: {app: web}
      ports: [{port: 8088, targetPort: 8080}]
  '';
in
pkgs.testers.runNixOSTest {
  name = if withK3s then "router-k3s" else "router";

  nodes = {
    # Fake ISP: DHCP for the router's WAN, a DNS zone, and a web server that echoes the
    # caller's address (proves NAT masquerading).
    isp = { lib, ... }: {
      virtualisation.vlans = [ 1 ];
      networking.useDHCP = false;
      networking.interfaces.eth1.ipv4.addresses = lib.mkForce [{ address = "10.99.0.1"; prefixLength = 24; }];
      networking.firewall.enable = false;
      services.dnsmasq = {
        enable = true;
        settings = {
          interface = "eth1";
          bind-interfaces = true;
          dhcp-range = "10.99.0.100,10.99.0.150,1h";
          address = "/example.test/10.99.0.1";
          no-resolv = true;
        };
      };
      systemd.services.echo-ip = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 ${pkgs.writeText "echo-ip.py" ''
          import http.server as h
          class H(h.BaseHTTPRequestHandler):
              def do_GET(self):
                  self.send_response(200); self.end_headers()
                  self.wfile.write(("hello from the internet, you are " + self.client_address[0]).encode())
          h.HTTPServer(("0.0.0.0", 80), H).serve_forever()
        ''}";
      };
      environment.systemPackages = [ pkgs.curl pkgs.netcat pkgs.dig ];
    };

    router = { lib, ... }: {
      imports = [ ../modules/router.nix ] ++ lib.optional withK3s ../modules/k3s.nix;
      # mkMerge/mkIf, not `//`: a shallow merge would replace the whole `router` attrset.
      config = lib.mkMerge [
        {
          virtualisation.vlans = [ 1 2 ];
          networking.interfaces.eth1.ipv4.addresses = lib.mkForce [ ];   # WAN: DHCP only
          networking.interfaces.eth2.ipv4.addresses = lib.mkForce [{ address = "10.88.0.1"; prefixLength = 24; }];
          services.openssh.enable = true;
          router = {
            enable = true;
            wan = "eth1";
            lan = "eth2";
            address = "10.88.0.1";
            prefixLength = 24;
            subnet = "10.88.0.0/24";
            dhcp.pool = "10.88.0.100 - 10.88.0.200";
            dhcp.reservations = [{ mac = "02:00:00:00:00:99"; ip = "10.88.0.50"; hostname = "fridge"; }];
            dns.upstreams = [ "10.99.0.1" ];
            dns.bootstrap = [ "10.99.0.1" ];
          };
          # The test VMs have no internet: no filter-list downloads.
          router.dns.filters = [ ];
          # exercise the typed DNS options
          router.dns.rewrites = [{ domain = "nas.example.home"; answer = "10.88.0.50"; }];
          router.dns.userRules = [ "||blocked.example.test^" ];
          router.dns.clients = [{ name = "speaker"; ids = [ "02:00:00:00:00:77" ]; filtering = false; }];
          environment.systemPackages = [ pkgs.iptables pkgs.dig ];
        }
        (lib.mkIf withK3s {
          # the real k3s module, with its images preloaded (no registry access in the sandbox)
          services.k3s.images = [ pkgs.k3s.passthru.airgap-images ];
          services.k3s.extraFlags = [ "--disable=traefik,metrics-server,local-storage" ];
          router.trustedInterfaces = [ "cni0" "flannel.1" ];
          virtualisation.memorySize = 3072;
          virtualisation.diskSize = 6144;
          virtualisation.cores = 2;
        })
      ];
    };

    client = { lib, ... }: {
      virtualisation.vlans = [ 2 ];
      networking.useNetworkd = true;
      networking.useDHCP = false;
      networking.interfaces.eth1.ipv4.addresses = lib.mkForce [ ];
      networking.interfaces.eth1.useDHCP = true;
      networking.firewall.allowedTCPPorts = [ 8000 ];
      # stands in for a k3s pod behind a ServiceLB port on the router
      systemd.services.pod = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server 8000 --directory /etc";
      };
      environment.systemPackages = [ pkgs.curl pkgs.dig pkgs.netcat ];
    };
  };

  testScript = ''
    start_all()
    isp.wait_for_unit("dnsmasq.service")
    isp.wait_for_unit("echo-ip.service")
    router.wait_for_unit("kea-dhcp4-server.service")
    router.wait_for_unit("adguardhome.service")
    router.wait_for_open_port(53, "10.88.0.1")

    with subtest("router gets its WAN address from the ISP by DHCP"):
        router.wait_until_succeeds("ip -4 -o addr show eth1 | grep -q 'inet 10.99.0.1[0-5][0-9]/'")
        wan_ip = router.succeed("ip -4 -o addr show eth1 | awk '{print $4}' | cut -d/ -f1").strip()
        router.succeed("ip route | grep -q 'default via 10.99.0.1 dev eth1'")

    with subtest("client gets a Kea lease with the router as gateway"):
        client.wait_until_succeeds("ip -4 -o addr show eth1 | grep -q 'inet 10.88.0.1[0-9][0-9]/'")
        client_ip = client.succeed("ip -4 -o addr show eth1 | awk '{print $4}' | cut -d/ -f1").strip()
        client.succeed("ip route | grep -q 'default via 10.88.0.1'")

    with subtest("DNS via AdGuard: upstream names + .lan reservations"):
        client.wait_until_succeeds("dig +short @10.88.0.1 example.test | grep -qx 10.99.0.1")
        client.succeed("dig +short @10.88.0.1 fridge.lan | grep -qx 10.88.0.50")
        client.succeed("dig +short @10.88.0.1 router.lan | grep -qx 10.88.0.1")
        client.succeed("dig +short @10.88.0.1 nas.example.home | grep -qx 10.88.0.50")
        # user rule blocks it (AdGuard answers 0.0.0.0 for blocked names)
        client.succeed("dig +short @10.88.0.1 blocked.example.test | grep -qx 0.0.0.0")
        # the DHCP-advertised resolver is the router
        client.wait_until_succeeds("resolvectl dns eth1 | grep -q 10.88.0.1")

    with subtest("NAT: the client reaches the internet, masqueraded as the router's WAN IP"):
        out = client.succeed("curl -sf -m 10 http://example.test/")
        assert f"you are {wan_ip}" in out, out

    with subtest("WAN side: router services unreachable; LAN side: reachable"):
        isp.fail(f"nc -z -w 3 {wan_ip} 22")
        isp.fail(f"nc -z -w 3 {wan_ip} 53")
        # a real UDP query: AdGuard would answer it if WAN:53 were open (dig exits 9 on no reply)
        isp.fail(f"dig +time=2 +tries=1 @{wan_ip} example.test")
        client.succeed("dig +time=2 +tries=1 @10.88.0.1 example.test")
        client.succeed("nc -z -w 3 10.88.0.1 22")

    with subtest("k3s ServiceLB-style DNAT is NOT reachable from the WAN"):
        # what ServiceLB/hostPort does: DNAT any local address:port to a pod
        router.succeed(f"iptables -t nat -I PREROUTING -p tcp --dport 9999 -m addrtype --dst-type LOCAL -j DNAT --to-destination {client_ip}:8000")
        client.wait_for_open_port(8000)
        isp.fail(f"curl -sf -m 5 http://{wan_ip}:9999/hostname")
        # control: without the WAN drop the same DNAT IS reachable, so the check above is meaningful
        router.succeed("iptables -t mangle -D PREROUTING -i eth1 -j router-wan-in")
        isp.succeed(f"curl -sf -m 5 http://{wan_ip}:9999/hostname")
        router.succeed("iptables -t mangle -I PREROUTING -i eth1 -j router-wan-in")
        isp.fail(f"curl -sf -m 5 http://{wan_ip}:9999/hostname")
  '' + pkgs.lib.optionalString withK3s ''

    with subtest("real k3s ServiceLB: LAN reaches the LoadBalancer port, WAN does not"):
        router.wait_for_unit("k3s.service")
        router.wait_until_succeeds("kubectl get node -o name | grep -q node/", timeout=300)
        router.wait_until_succeeds("kubectl wait --for=condition=Ready node --all --timeout=10s", timeout=300)
        router.succeed("kubectl apply -f ${webManifest}")
        router.wait_until_succeeds("kubectl get pods -l app=web -o jsonpath={.items[0].status.phase} | grep -qx Running", timeout=300)
        router.wait_until_succeeds("kubectl -n kube-system get pods -l svccontroller.k3s.cattle.io/svcname=web -o jsonpath={.items[0].status.phase} | grep -qx Running", timeout=300)
        client.wait_until_succeeds("curl -sf -m 5 http://10.88.0.1:8088/ | grep -q hello-from-pod", timeout=120)
        isp.fail(f"curl -sf -m 5 http://{wan_ip}:8088/")
        # control: without the WAN drop, ServiceLB WOULD expose it on the WAN address
        router.succeed("iptables -t mangle -D PREROUTING -i eth1 -j router-wan-in")
        isp.wait_until_succeeds(f"curl -sf -m 5 http://{wan_ip}:8088/ | grep -q hello-from-pod", timeout=60)
        router.succeed("iptables -t mangle -I PREROUTING -i eth1 -j router-wan-in")
        isp.fail(f"curl -sf -m 5 http://{wan_ip}:8088/")
  '';
}
