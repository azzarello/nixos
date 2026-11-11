# VM test for router.dnsOnly: AdGuard Home alone on a LAN host that is NOT the router (no Kea, no NAT, no
# forwarding). Used to trial breaker's DNS before the cutover: the Deco stays router + DHCP and only its DNS
# setting points here.
#   nix build .#checks.x86_64-linux.router-dns-only   (needs KVM; run it on breaker)
{ pkgs, ... }:
pkgs.testers.runNixOSTest {
  name = "router-dns-only";
  nodes = {
    # upstream resolver standing in for the internet
    upstream = { lib, ... }: {
      virtualisation.vlans = [ 1 ];
      networking.useDHCP = false;
      networking.interfaces.eth1.ipv4.addresses = lib.mkForce [{ address = "10.77.0.2"; prefixLength = 24; }];
      networking.firewall.enable = false;
      services.dnsmasq = {
        enable = true;
        settings = { interface = "eth1"; bind-interfaces = true; address = "/example.test/10.77.0.2"; no-resolv = true; };
      };
    };
    dns = { lib, ... }: {
      imports = [ ../modules/router.nix ];
      virtualisation.vlans = [ 1 ];
      networking.useDHCP = false;
      networking.interfaces.eth1.ipv4.addresses = lib.mkForce [{ address = "10.77.0.10"; prefixLength = 24; }];
      router = {
        dnsOnly = true;
        wan = "eth0"; lan = "eth1";
        address = "10.77.0.1"; prefixLength = 24; subnet = "10.77.0.0/24";   # unused in dnsOnly mode
        dhcp.pool = "10.77.0.100 - 10.77.0.200";
        dhcp.reservations = [{ mac = "02:00:00:00:00:99"; ip = "10.77.0.50"; hostname = "fridge"; }];
        dns.upstreams = [ "10.77.0.2" ];
        dns.bootstrap = [ "10.77.0.2" ];
        dns.filters = [ ];
        dns.listenAddresses = [ "10.77.0.10" ];
        dns.rewrites = [{ domain = "*.home.test"; answer = "10.77.0.10"; }];
        dns.userRules = [ "||blocked.example.test^" ];
      };
    };
    client = { lib, ... }: {
      virtualisation.vlans = [ 1 ];
      networking.useDHCP = false;
      networking.interfaces.eth1.ipv4.addresses = lib.mkForce [{ address = "10.77.0.20"; prefixLength = 24; }];
      environment.systemPackages = [ pkgs.dig ];
    };
  };
  testScript = ''
    start_all()
    upstream.wait_for_unit("dnsmasq.service")
    dns.wait_for_unit("adguardhome.service")
    dns.wait_for_open_port(53, "10.77.0.10")

    with subtest("the LAN resolves through it: upstream names, wildcard rewrite, .lan reservation, user rule"):
        client.wait_until_succeeds("dig +short @10.77.0.10 example.test | grep -qx 10.77.0.2")
        client.succeed("dig +short @10.77.0.10 anything.home.test | grep -qx 10.77.0.10")
        client.succeed("dig +short @10.77.0.10 fridge.lan | grep -qx 10.77.0.50")
        client.succeed("dig +short @10.77.0.10 blocked.example.test | grep -qx 0.0.0.0")
        client.succeed("dig +short +tcp @10.77.0.10 example.test | grep -qx 10.77.0.2")

    with subtest("it is only DNS: no DHCP server, no routing, no NAT"):
        dns.fail("systemctl is-active kea-dhcp4-server.service")
        dns.succeed("test \"$(cat /proc/sys/net/ipv4/ip_forward)\" = 0")
        dns.fail("iptables -t nat -S | grep -q MASQUERADE")
  '';
}
