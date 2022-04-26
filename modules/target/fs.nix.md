/*

# File System Configuration for the Target Device

For the file system setup, the relevant characteristics of the target devices are that it:
* can boot into multiple (non-generational) configurations
* is robust, that is, there is a fallback (default/`null`) config that the other configurations can't destroy.

To realize that, the target devices use a `tmpfs` for `/`, meaning that in most locations, all files will be deleted/reset on reboot.

The only persistent paths are:
* `/boot` for the (single) kernel and initrd, backed by a `vfat` boot/firmware partition (if the hardware's boot architecture requires one and/or can't open `ext4` partitions),
* `/nix/store` which contains all the programs and configurations, backed by an `ext4` system partition,
* `/var/log` and `/volumes` for logs and container volumes, backed by per-config directories on an `ext4` data partition.

The boot and system partitions are mounted read-only in all but the fallback config, and the data partition is not mounted in the fallback config.
That way, no part that is relevant for the booting of the fallback config can be modified in any other config.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: { config, pkgs, lib, ... }: let inherit (inputs.self) lib; in let
    cfg = config.th.target.fs;
in {

    options.th = { target.fs = {
        enable = lib.mkEnableOption "the file systems for a target device";
        vfatBoot = lib.mkOption { description = "Path at which to mount a vfat boot/firmware partition. Set to »null« if not required by the boot architecture."; type = lib.types.nullOr lib.types.str; default = "/boot"; };
        mbrBoot = lib.mkOption { description = "Whether to create a hybrid MBR for the boot partition."; type = lib.types.bool; default = cfg.vfatBoot != null; };
        writable = lib.mkOption { description = "Whether /nix/store and /boot are writable of not."; type = lib.types.bool; default = cfg.dataDir == null; };
        dataDir = lib.mkOption { description = "Dir on /data partition that on which logs and volumes are stored. /data part won't be mounted if »null«."; type = lib.types.nullOr lib.types.str; default = null; };
        dataSize = lib.mkOption { description = "Size of the »/data« partition."; type = lib.types.str; default = "2G"; };
    }; };

    config = let
        hash = builtins.substring 0 8 (builtins.hashString "sha256" config.networking.hostName);
        implied = true; # some mount points are implied (and forced) to be »neededForBoot« in »specialArgs.utils.pathsNeededForBoot« (this marks those here)

    in lib.mkIf cfg.enable (lib.mkMerge [ (lib.mkIf (cfg.vfatBoot != null) {
        # If required, declare and mount the boot partition:

        installer.partitions."boot-${hash}" = { type = "ef00"; size = "64M"; index = 1; order = 1500; };
        installer.disks = lib.mkIf cfg.mbrBoot { primary = { mbrParts = "1"; extraFDiskCommands = ''
            t;1;b  # type ; part1 ; W95 FAT32
            a;1    # active/boot ; part1
        ''; }; };
        fileSystems.${cfg.vfatBoot} = { fsType  =   "vfat";    device = "/dev/disk/by-partlabel/boot-${hash}"; neededForBoot = implied; options = [ "noatime" ]; formatOptions = "-F 32"; };

    }) ({
        # Mount a tmpfs as root, and (currently) only the nix-store from a system partition:

        fileSystems."/"             = { fsType  =  "tmpfs";    device = "tmpfs"; neededForBoot = implied; };

        installer.partitions."system-${hash}" = { type = "8300"; size = null; order = 500; };
        fileSystems."/system"       = { fsType  =   "ext4";    device = "/dev/disk/by-partlabel/system-${hash}"; neededForBoot = true; options = [ "noatime" ]; formatOptions = "-O inline_data -E nodiscard"; };
        fileSystems."/nix/store"    = { options = ["bind,ro"]; device = "/system/nix/store"; neededForBoot = implied; };

    }) (lib.mkIf (!cfg.writable) {
        # Make system and boot partition read-only, unless in default/fallback spec (might want to have a special spec and/or setting for this):

        fileSystems = (if (cfg.vfatBoot != null) then {
            ${cfg.vfatBoot} = { options = [ "ro" ]; };
        } else { }) // {
            "/system"       = { options = [ "ro" ]; };
        };

    }) ({
        # Any file systems marked as neededForBoot are mounted in the initramfs, and since all specs share the default initramfs, any differences in those file systems has to be applied here:

        boot.initrd.postMountCommands = ''
            # apply mount options per specialisation
            if [ -e /run/current-specialisation ] ; then
                ${lib.optionalString (cfg.vfatBoot != null) ''
                    mount -o remount,ro $targetRoot${cfg.vfatBoot}
                ''}
                mount -o remount,ro $targetRoot/system
            fi
        '';

    }) ({
        # Declare data partition:

        installer.partitions."data-${hash}" = { type = "8300"; size = cfg.dataSize; order = 1000; };

    }) (lib.mkIf (cfg.dataDir == null) {
        # Make /data mountable in default spec, to be able to set the next-specialisation marker:

        fileSystems."/data"         = { fsType  =   "ext4";    device = "/dev/disk/by-partlabel/data-${hash}"; neededForBoot = false; options = [ "noatime" "noauto" "nofail" ]; formatOptions = "-O inline_data -E nodiscard"; };

    }) (lib.mkIf (cfg.dataDir != null) {
        # On a read/writable data partition, provide persistent logs and container volume storage separately for each spec:

        fileSystems."/data"         = { fsType  =   "ext4";    device = "/dev/disk/by-partlabel/data-${hash}"; neededForBoot = true; options = [ "noatime" ]; };
        fileSystems."/var/log"      = { options = [ "bind" ];  device = "/data/by-config/${cfg.dataDir}/log"; neededForBoot = implied; };
        fileSystems."/volumes"      = { options = [ "bind" ];  device = "/data/by-config/${cfg.dataDir}/volumes"; neededForBoot = false; };

    }) ({
        # Ensure bind-mount "device" exists for the current spec (must be included for all / the default spec, since only that actually has an initrd):

        boot.initrd.postDeviceCommands = ''
            # hack to make sure the bind-mount "device"s exist
            if [ -e /run/current-specialisation ] ; then
                mkdir /tmp/data-mnt ; mount -t ext4 /dev/disk/by-partlabel/data-${hash} /tmp/data-mnt
                mkdir -p /tmp/data-mnt/by-config/$(cat /run/current-specialisation)/log
                mkdir -p /tmp/data-mnt/by-config/$(cat /run/current-specialisation)/volumes
                umount /tmp/data-mnt ; rmdir /tmp/data-mnt
            fi
        '';

    }) ]);

}
