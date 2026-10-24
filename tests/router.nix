# VM test for modules/router.nix:  isp (fake upstream) <-vlan1-> router <-vlan2-> client
#   nix build .#checks.x86_64-linux.router        (needs KVM; run it on breaker)
{ pkgs, ... }:
pkgs.testers.runNixOSTest {
  name = "router";

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
      imports = [ ../modules/router.nix ];
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
      services.adguardhome.settings.filters = lib.mkForce [ ];
      environment.systemPackages = [ pkgs.iptables pkgs.dig ];
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
  '';
}
