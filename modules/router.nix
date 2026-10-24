# Home router role: WAN DHCP client, LAN gateway with NAT, DHCP server (Kea), DNS (AdGuard
# Home). Off by default (`router.enable`); hosts opt in. Design + cutover runbook: docs/router.md.
# Tested by tests/router.nix (fake ISP <-> router <-> LAN client VMs).
#
# Security model: the WAN side accepts NOTHING unsolicited. Inbound NEW connections on the WAN
# interface are dropped in mangle/PREROUTING, i.e. BEFORE any DNAT. That matters on a k3s host:
# ServiceLB/hostPort DNAT matches every local address, so without this every LoadBalancer
# port would be reachable from the internet even though the INPUT firewall is closed.
{ config, lib, pkgs, ... }:
let
  cfg = config.router;
  inherit (lib) mkOption mkEnableOption mkIf types;
  ipt = "${pkgs.iptables}/bin/iptables";
in
{
  options.router = {
    enable = mkEnableOption "home router role";
    wan = mkOption { type = types.str; description = "WAN interface (DHCP client toward the ISP)."; };
    lan = mkOption { type = types.str; description = "LAN interface (gateway for the home network)."; };
    address = mkOption { type = types.str; example = "192.168.68.1"; description = "Router's LAN address."; };
    prefixLength = mkOption { type = types.int; default = 24; };
    subnet = mkOption { type = types.str; example = "192.168.68.0/22"; description = "LAN subnet (CIDR)."; };
    dhcp = {
      pool = mkOption { type = types.str; example = "192.168.69.1 - 192.168.70.254"; };
      leaseSeconds = mkOption { type = types.int; default = 86400; };
      reservations = mkOption {
        default = [ ];
        description = "Fixed leases: { mac, ip, hostname }.";
        type = types.listOf (types.submodule {
          options = {
            mac = mkOption { type = types.str; };
            ip = mkOption { type = types.str; };
            hostname = mkOption { type = types.str; };
          };
        });
      };
    };
    dns = {
      upstreams = mkOption {
        type = types.listOf types.str;
        default = [ "https://dns.quad9.net/dns-query" "https://cloudflare-dns.com/dns-query" ];
      };
      bootstrap = mkOption { type = types.listOf types.str; default = [ "9.9.9.9" "1.1.1.1" ]; };
      filters = mkOption {
        description = "Blocklists (AdGuard filter URLs).";
        type = types.listOf (types.submodule { options = { name = mkOption { type = types.str; }; url = mkOption { type = types.str; }; }; });
        default = [{ name = "AdGuard DNS filter"; url = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt"; }];
      };
      userRules = mkOption { type = types.listOf types.str; default = [ ]; description = "AdGuard custom filtering rules."; };
      rewrites = mkOption {
        description = "Extra DNS rewrites (domain -> answer), on top of <reservation>.lan and router.lan.";
        type = types.listOf (types.submodule { options = { domain = mkOption { type = types.str; }; answer = mkOption { type = types.str; }; }; });
        default = [ ];
      };
      clients = mkOption {
        description = "Named clients (by MAC/IP). filtering = false exempts a device from blocklists.";
        type = types.listOf (types.submodule { options = {
          name = mkOption { type = types.str; };
          ids = mkOption { type = types.listOf types.str; };
          filtering = mkOption { type = types.bool; default = true; };
        }; });
        default = [ ];
      };
      dnssec = mkOption { type = types.bool; default = true; };
      cacheSize = mkOption { type = types.int; default = 4194304; };
      upstreamMode = mkOption { type = types.enum [ "load_balance" "parallel" "fastest_addr" ]; default = "load_balance"; };
    };
    trustedInterfaces = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Extra interfaces allowed to reach router services like the LAN (e.g. tailscale0).";
    };
  };

  config = mkIf cfg.enable {
    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
      # IPv6 routing is out of scope for now (docs/router.md): no RA/DHCPv6 on the LAN.
      "net.ipv6.conf.${cfg.wan}.accept_ra" = 2;
    };

    networking.useNetworkd = true;
    networking.useDHCP = false;
    networking.interfaces.${cfg.wan}.useDHCP = true;
    networking.interfaces.${cfg.lan} = {
      useDHCP = false;
      ipv4.addresses = [{ address = cfg.address; prefixLength = cfg.prefixLength; }];
    };
    # Don't let the WAN's DHCP-provided DNS become the router's resolver: use our own.
    systemd.network.networks."40-${cfg.wan}".dhcpV4Config.UseDNS = false;
    networking.nameservers = [ "127.0.0.1" ];
    services.resolved.settings.Resolve.DNSStubListener = "no";

    networking.nat = {
      enable = true;
      externalInterface = cfg.wan;
      internalInterfaces = [ cfg.lan ];
    };

    networking.firewall = {
      enable = true;
      # Nothing is opened globally; services are allowed per trusted interface below.
      allowedTCPPorts = lib.mkForce [ ];
      allowedUDPPorts = lib.mkForce [ ];
      interfaces = lib.genAttrs ([ cfg.lan ] ++ cfg.trustedInterfaces) (_: {
        allowedTCPPorts = [ 22 53 80 443 6443 ];
        allowedUDPPorts = [ 53 67 ];
      });
      extraCommands = ''
        # WAN: drop every unsolicited inbound connection before DNAT (see header comment).
        ${ipt} -t mangle -N router-wan-in 2>/dev/null || ${ipt} -t mangle -F router-wan-in
        ${ipt} -t mangle -A router-wan-in -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
        ${ipt} -t mangle -A router-wan-in -p udp --sport 67 --dport 68 -j RETURN   # DHCP replies
        ${ipt} -t mangle -A router-wan-in -p icmp --icmp-type destination-unreachable -j RETURN
        ${ipt} -t mangle -A router-wan-in -p icmp --icmp-type time-exceeded -j RETURN
        ${ipt} -t mangle -A router-wan-in -j DROP
        ${ipt} -t mangle -C PREROUTING -i ${cfg.wan} -j router-wan-in 2>/dev/null ||
          ${ipt} -t mangle -I PREROUTING -i ${cfg.wan} -j router-wan-in
      '';
      extraStopCommands = ''
        ${ipt} -t mangle -D PREROUTING -i ${cfg.wan} -j router-wan-in 2>/dev/null || true
        ${ipt} -t mangle -F router-wan-in 2>/dev/null || true
        ${ipt} -t mangle -X router-wan-in 2>/dev/null || true
      '';
    };
    # The default openssh module opens 22 on EVERY interface; the router allows it on LAN only.
    services.openssh.openFirewall = false;

    services.kea.dhcp4 = {
      enable = true;
      settings = {
        interfaces-config.interfaces = [ cfg.lan ];
        lease-database = { type = "memfile"; persist = true; name = "/var/lib/kea/dhcp4.leases"; };
        valid-lifetime = cfg.dhcp.leaseSeconds;
        renew-timer = cfg.dhcp.leaseSeconds / 2;
        rebind-timer = cfg.dhcp.leaseSeconds * 7 / 8;
        subnet4 = [{
          id = 1;
          subnet = cfg.subnet;
          pools = [{ pool = cfg.dhcp.pool; }];
          option-data = [
            { name = "routers"; data = cfg.address; }
            { name = "domain-name-servers"; data = cfg.address; }
          ];
          reservations = map (r: { hw-address = r.mac; ip-address = r.ip; hostname = r.hostname; }) cfg.dhcp.reservations;
        }];
      };
    };

    services.adguardhome = {
      enable = true;
      mutableSettings = false;
      settings = {
        dns = {
          bind_hosts = [ "127.0.0.1" cfg.address ];
          port = 53;
          upstream_dns = cfg.dns.upstreams;
          bootstrap_dns = cfg.dns.bootstrap;
          upstream_mode = cfg.dns.upstreamMode;
          enable_dnssec = cfg.dns.dnssec;
          cache_size = cfg.dns.cacheSize;
          # Lesson from fridge (2026-10-23): AdGuard's default per-/24 ratelimit made the whole
          # LAN share one 100 qps budget and silently dropped queries. A router serves its LAN.
          ratelimit = 0;
          # Local names from DHCP reservations (e.g. fridge.lan).
          local_ptr_upstreams = [ ];
        };
        filtering.rewrites = map (r: { domain = "${r.hostname}.lan"; answer = r.ip; enabled = true; }) cfg.dhcp.reservations
          ++ [{ domain = "router.lan"; answer = cfg.address; enabled = true; }]
          ++ map (r: r // { enabled = true; }) cfg.dns.rewrites;
        filters = lib.imap1 (i: f: { enabled = true; inherit (f) url name; id = i; }) cfg.dns.filters;
        user_rules = cfg.dns.userRules;
        clients.persistent = map (c: {
          inherit (c) name ids;
          use_global_settings = c.filtering;
          filtering_enabled = c.filtering;
          parental_enabled = false;
          safebrowsing_enabled = false;
          use_global_blocked_services = true;
        }) cfg.dns.clients;
      };
    };
    # AdGuard must start after the LAN address exists.
    systemd.services.adguardhome = {
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
    };
  };
}
