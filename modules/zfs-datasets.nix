# Declarative ZFS datasets: `zfs.datasets.<name> = { mountpoint = ...; properties = {...}; }`.
# A oneshot creates any that are missing and converges properties on every boot/switch.
# It never destroys anything: removing a dataset from config just stops managing it.
# `zfs.optionalPools`: pools the host boots fine without (rebuildable data). Their import is wanted, not required, by
# zfs-import.target, and their datasets are skipped while the pool isn't imported, so a missing or failed pool
# degrades only what uses it instead of failing zfs-import.target and everything ordered after it.
{ config, lib, pkgs, ... }:
let
  cfg = config.zfs.datasets;
  optional = config.zfs.optionalPools;
  zfs = "${config.boot.zfs.package}/bin/zfs";
  zpool = "${config.boot.zfs.package}/bin/zpool";
  poolOf = name: builtins.head (lib.splitString "/" name);
  ensure = name: ds: if builtins.elem (poolOf name) optional then ''
    if ${zpool} list -H -o name ${lib.escapeShellArg (poolOf name)} >/dev/null 2>&1; then
    ${ensureDs name ds}
    else
      echo "pool ${poolOf name} not imported (optional): skipping ${name}"
    fi
  '' else ensureDs name ds;
  ensureDs = name: ds: ''
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
  options.zfs.optionalPools = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "Pools in boot.zfs.extraPools the host boots without: import wanted not required, datasets skipped if absent.";
  };

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
    assertions = map (p: {
      assertion = builtins.elem p config.boot.zfs.extraPools;
      message = "zfs.optionalPools: ${p} is not in boot.zfs.extraPools";
    }) optional;
    # upstream's import unit is requiredBy zfs-import.target (and the pool's fileSystems mounts; an optional pool
    # mounts by its mountpoint property, so it has none): keep the ordering, drop the requirement
    systemd.services = lib.genAttrs (map (p: "zfs-import-${p}") optional) (_: {
      requiredBy = lib.mkForce [ ];
      wantedBy = [ "zfs-import.target" ];
    }) // {
      zfs-datasets = {
        description = "Create/converge declared ZFS datasets";
        wantedBy = [ "multi-user.target" ];
        after = [ "zfs-import.target" "zfs-mount.service" ];
        requires = [ "zfs-import.target" ];
        serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
        script = lib.concatStrings (lib.mapAttrsToList ensure cfg);
      };
    };
  };
}
