# Single SATA boot drive: 1G ESP + btrfs with subvolumes.
# No LUKS on purpose: as the future router this box must come back unattended after a power cut.
# Pinned to the Patriot P220 128GB SATA SSD (serial P220EDBB23100403150). The NVMe is NOT managed here.
{
  disko.devices.disk.main = {
    type = "disk";
    device = "/dev/disk/by-id/ata-Patriot_P220_128GB_P220EDBB23100403150";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          size = "1G";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };
        root = {
          size = "100%";
          content = {
            type = "btrfs";
            extraArgs = [ "-f" ];
            subvolumes = {
              "/root" = { mountpoint = "/"; mountOptions = [ "compress=zstd" "noatime" ]; };
              "/home" = { mountpoint = "/home"; mountOptions = [ "compress=zstd" "noatime" ]; };
              "/nix" = { mountpoint = "/nix"; mountOptions = [ "compress=zstd" "noatime" ]; };
              "/log" = { mountpoint = "/var/log"; mountOptions = [ "compress=zstd" "noatime" ]; };
            };
          };
        };
      };
    };
  };
}
