/*

# Installer Declarations

Options to declare Disks and Partitions to be picked up by the installer scripts.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: { config, pkgs, lib, ... }: let inherit (inputs.self) lib; in let
    cfg = config.installer;
in {

    options = { installer = {
        disks = lib.mkOption {
            description = "Set of disks that this host will be installed on.";
            type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: { options = {
                name = lib.mkOption { description = "Name that this disk is being referred to as in other places."; type = lib.types.str; default = name; readOnly = true; };
                size = lib.mkOption { description = "The size of the image to create, when using an image for this disk, as argument to »fallocate -l«."; type = lib.types.str; default = "8G"; };
                serial = lib.mkOption { description = "Serial number of the specific hardware disk to use. If set the disk path passed to the installer must point to the device with this serial. Use »udevadm info --query=property --name=$DISK | grep -oP 'ID_SERIAL_SHORT=\K.*'« to get the serial."; type = lib.types.nullOr lib.types.str; default = null; };
                alignment = lib.mkOption { description = "Partition alignment quantifier. Should be at least the optimal physical write size of the disk, but going larger at worst wastes this many times the number of partitions disk sectors."; type = lib.types.int; default = 16384; };
                mbrParts = lib.mkOption { description = "Up to three colon-separated (GPT) partition numbers that will be made available in a hybrid MBR."; type = lib.types.nullOr lib.types.str; default = null; };
                extraFDiskCommands = lib.mkOption { description = "»fdisk« menu commands to run against the hybrid MBR. ».mbrParts« 1[2[3]] exist as transfers from the GPT table, and part4 is the protective GPT part. Can do things like marking partitions as bootable or changing their type. Spaces and end-of-line »#«-prefixed comments are removed, new lines and »;« also mean return."; type = lib.types.lines; default = null; example = ''
                    t;1;b  # type ; part1 ; W95 FAT32
                    a;1    # active/boot ; part1
                ''; };
            }; }));
            default = { primary = { }; };
        };
        partitions = lib.mkOption {
            description = "Set of disks disk partitions that the system will need/use. Partitions will be created on their respective ».disk«s in ».order« using »sgdisk -n X:+0+$size«.";
            type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: { options = {
                name = lib.mkOption { description = "Name/partlabel that this partition can be referred to as once created."; type = lib.types.str; default = name; readOnly = true; };
                disk = lib.mkOption { description = "Name of the disk that this partition resides on."; type = lib.types.str; default = "primary"; };
                type = lib.mkOption { description = "»gdisk« partition type of this partition."; type = lib.types.str; };
                size = lib.mkOption { description = "Partition size, as number suffixed with »K«, »M«, »G«, etc. Or »null« to fill the remaining disk space."; type = lib.types.nullOr lib.types.str; default = null; };
                index = lib.mkOption { description = "Optionally explicit partition table index to place this partition in. Use ».order« to make sure that this index hasn't been used yet.."; type = lib.types.nullOr lib.types.int; default = null; };
                order = lib.mkOption { description = "Creation order ranking of this partition. Higher orders will be created first, and will thus be placed earlier in the partition table (if ».index« isn't explicitly set) and also further to the front of the disk space."; type = lib.types.int; default = 1000; };
            }; }));
            default = { };
        };
        partitionList = lib.mkOption { description = "Partitions as a sorted list"; type = lib.types.listOf (lib.types.attrsOf lib.types.anything); default = lib.mapAttrsToList (name: part: lib.mkOrder part.order (builtins.removeAttrs part [ "order" ])) cfg.partitions; readOnly = true; internal = true; };
    }; };

}
