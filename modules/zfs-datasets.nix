# Declarative ZFS datasets: `zfs.datasets.<name> = { mountpoint = ...; properties = {...}; }`.
# A oneshot creates any that are missing and converges properties on every boot/switch.
# It never destroys anything: removing a dataset from config just stops managing it.
{ config, lib, pkgs, ... }:
let
  cfg = config.zfs.datasets;
  zfs = "${config.boot.zfs.package}/bin/zfs";
  ensure = name: ds: ''
    if ! ${zfs} list -H -o name ${lib.escapeShellArg name} >/dev/null 2>&1; then
      echo "creating ${name}"
      ${zfs} create -p -o mountpoint=${lib.escapeShellArg ds.mountpoint} ${lib.escapeShellArg name}
    fi
    ${lib.concatStrings (lib.mapAttrsToList (k: v: ''
      [ "$(${zfs} get -H -o value ${k} ${lib.escapeShellArg name})" = ${lib.escapeShellArg v} ] || \
        ${zfs} set ${k}=${lib.escapeShellArg v} ${lib.escapeShellArg name}
    '') ({ mountpoint = ds.mountpoint; } // ds.properties))}
  '';
in
{
  options.zfs.datasets = lib.mkOption {
    default = { };
    description = "ZFS datasets to create (if missing) and keep properties converged on.";
    type = lib.types.attrsOf (lib.types.submodule {
      options = {
        mountpoint = lib.mkOption { type = lib.types.str; };
        properties = lib.mkOption { type = lib.types.attrsOf lib.types.str; default = { }; };
      };
    });
  };

  config = lib.mkIf (cfg != { }) {
    systemd.services.zfs-datasets = {
      description = "Create/converge declared ZFS datasets";
      wantedBy = [ "multi-user.target" ];
      after = [ "zfs-import.target" "zfs-mount.service" ];
      requires = [ "zfs-import.target" ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = lib.concatStrings (lib.mapAttrsToList ensure cfg);
    };
  };
}
