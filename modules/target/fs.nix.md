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
dirname: inputs: { config, pkgs, lib, ... }: let lib = inputs.self.lib.__internal__; in let
    cfg = config.th.target.fs;
in {

    options.th = { target.fs = {
        enable = lib.mkEnableOption "the file systems for a target device";
        dataDir = lib.mkOption { description = "Dir on /data partition that on which logs and volumes are stored. /data part won't be mounted if »null«."; type = lib.types.nullOr lib.types.str; default = null; };
        dataSize = lib.mkOption { description = "Size of the »/data« partition."; type = lib.types.str; default = "2G"; };
    }; };

    config = let
        hash = builtins.substring 0 8 (builtins.hashString "sha256" config.networking.hostName);
        implied = true; # some mount points are implied (and forced) to be »neededForBoot« in »specialArgs.utils.pathsNeededForBoot« (this marks those here)

    in lib.mkIf cfg.enable (lib.mkMerge [ ({
        # Mount a tmpfs as root, and (currently) only the nix-store from a read-only system partition:

        fileSystems."/"             = { fsType  =  "tmpfs";    device = "tmpfs"; neededForBoot = implied; options = [ "mode=755" ]; };

        setup.disks.partitions."system-${hash}" = { type = "8300"; size = null; order = 500; };
        fileSystems."/system"       = { fsType  =   "ext4";    device = "/dev/disk/by-partlabel/system-${hash}"; neededForBoot = true; options = [ "noatime" "ro" ]; formatArgs = [ "-O" "inline_data" "-b" "4k" "-E" "nodiscard" "-F" ]; };
        fileSystems."/nix/store"    = { options = [ "bind" "ro" "private" ]; device = "/system/nix/store"; neededForBoot = implied; };

        systemd.tmpfiles.rules = [
            # Make the »/nix/store« non-enumerable:
            ''d  /system/nix/store          0751 root 30000 - -''
            # »nixos-containers«/»config.containers« expect these to exist and fail to start without:
            ''d  /nix/var/nix/db            0755 root root - -''
            ''d  /nix/var/nix/daemon-socket 0755 root root - -''
        ];

    }) ({
        # Declare data partition:

        setup.disks.partitions."data-${hash}" = { type = "8300"; size = cfg.dataSize; order = 1000; };

    }) (lib.mkIf (cfg.dataDir == null) {
        # Make /data mountable in default spec:

        fileSystems."/data"         = { fsType  =   "ext4";    device = "/dev/disk/by-partlabel/data-${hash}"; neededForBoot = false; options = [ "noatime" "noauto" "nofail" ]; formatArgs = [ "-O" "inline_data" "-E" "nodiscard" "-F" ]; };

    }) (lib.mkIf (cfg.dataDir != null) {
        # On a read/writable data partition, provide persistent logs and container volume storage separately for each spec:

        fileSystems."/data"         = { fsType  =   "ext4";    device = "/dev/disk/by-partlabel/data-${hash}"; neededForBoot = true; options = [ "noatime" ]; };
        fileSystems."/var/log"      = { options = [ "bind" ];  device = "/data/by-config/${cfg.dataDir}/log"; neededForBoot = implied; };
        fileSystems."/volumes"  = rec { options = [ "bind" ];  device = "/data/by-config/${cfg.dataDir}/volumes"; neededForBoot = false; preMountCommands = "mkdir -p -- ${lib.escapeShellArg device}"; };

    }) ]);

}
