/*

# Bootloader in Nix

The existing NixOS bootloader configurations create a script that is called during activation and builds the actual bootloader config under inclusion of external system state.
Overall, these bootloaders are thus not hermetic.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: { config, pkgs, lib, ... }: let inherit (inputs.self) lib; in let
    cfg = config.th.hermetic-bootloader;
    hash = builtins.substring 0 8 (builtins.hashString "sha256" config.networking.hostName);
in {

    options.th = { hermetic-bootloader = {
        enable = lib.mkEnableOption "building the bootloader configuration hermetically in Nix";
        loader = lib.mkOption { description = "The boot loader to generate the configuration for."; type = lib.types.enum [ "systemd-boot" "uboot-extlinux" ]; default = "systemd-boot"; };
        extraFiles = lib.mkOption { description = "Additional files to include in the boot partition."; type = lib.types.attrsOf lib.types.path; default = { }; };
        extraGptOffset = lib.mkOption { description = "Additional space to clear at the start and end of the boot disk, for firmware and such."; type = lib.types.ints.unsigned; default = 0; };

        uboot.base = lib.mkOption { description = "... The result of calling »pkgs.buildUboot« (or equivalent)."; type = lib.types.nullOr lib.types.package; default = null; };
        uboot.env = lib.mkOption { description = "Base u-boot env. Must set »scriptaddr«, »kernel_addr_r«, »fdt_addr_r«, »ramdisk_addr_r«, and »fdtfile« (unless the ».base« u-boot already configures those)."; type = lib.types.attrsOf lib.types.string; default = null; };
        uboot.extraConfig = lib.mkOption { description = "."; type = lib.types.listOf lib.types.string; default = [ ]; };
        uboot.mmcDev = lib.mkOption { description = "MMC device number that u-boot should use."; type = lib.types.ints.between 0 128; default = null; };
        uboot.result = lib.mkOption { description = "The resulting reconfigured u-boot. For a rPI, this can be passed back as ».extraFiles« (with a matching »config.txt«), other boards may need to directly flash this somewhere."; type = lib.types.nullOr lib.types.package; };

        default = lib.mkOption { description = "Entry to boot as default. Must be the name of a (non-»null«) ».entry«."; type = lib.types.nullOr lib.types.str; };
        entries = lib.mkOption {
            description = "Entries to list in the bootloader.";
            type = lib.types.attrsOf (lib.types.nullOr (lib.types.submodule ({ name, config, options, ... }: { options = {
                name = lib.mkOption { description = "Attribute name as the name of the bootloader entry within the NixOS configuration."; type = lib.types.str; default = name; readOnly = true; };
                nixosConfig = lib.mkOption { description = ""; default = null; };
                title = lib.mkOption { description = ""; type = lib.types.str; default = "NixOS"; };
                id = lib.mkOption { description = ""; type = lib.types.str; };
                kernel = lib.mkOption { description = ""; type = lib.types.path; };
                initrd = lib.mkOption { description = ""; type = lib.types.path; };
                cmdline = lib.mkOption { description = ""; type = lib.types.singleLineStr; };
                deviceTree = lib.mkOption { description = ""; type = lib.types.nullOr lib.types.path; };
                machine-id = lib.mkOption { description = ""; type = lib.types.nullOr lib.types.singleLineStr; };
            }; config = let
                inherit (config) nixosConfig; # Derive defaults from ».nixosConfig«:
            in {
                id = lib.mkOptionDefault (if nixosConfig == null then name else "${name}-${builtins.substring 11 8 nixosConfig.system.build.toplevel}");
                kernel = lib.mkOptionDefault "${nixosConfig.system.build.kernel}/${nixosConfig.system.boot.loader.kernelFile}";
                initrd = lib.mkOptionDefault "${nixosConfig.system.build.initialRamdisk}/${nixosConfig.system.boot.loader.initrdFile}";
                cmdline = lib.mkOptionDefault "init=${nixosConfig.system.build.toplevel}/init ${lib.concatStringsSep " " nixosConfig.boot.kernelParams}"; # init can't be »nixosConfig.system.build.bootStage2« because that lacks the correct reference to »...toplevel.out«
                deviceTree = lib.mkOptionDefault (if nixosConfig == null then null else nixosConfig.hardware.deviceTree.package);
                machine-id = lib.mkOptionDefault (lib.attrByPath [ "environment" "etc" "machine-id" "text" ] null nixosConfig);
            }; })));
            default = { };
            apply = entries: lib.mapAttrs (k: v: builtins.removeAttrs v [ "nixosConfig" ]) (lib.filterAttrs (k: v: v != null) entries);
        };

        slots.disk = lib.mkOption { description = ""; type = lib.types.str; default = "primary"; };
        slots.size = lib.mkOption { description = "Size of the boot slots."; type = lib.types.str; default = "64M"; };
        slots.number = lib.mkOption { description = "Number of boot slots."; type = lib.types.ints.between 2 8; default = 2; };
        slots.currentLabel = lib.mkOption { description = "FS label of the boot slot written by the current config build. Must be unique to each build and at most 11 bytes long. This can't refer to the build output, as that would create a loop. Using the input sources works (as they should be the only thing dictating the build output), but can cause unnecessary changes to »/etc/fstab«, thus »/etc«, and the bootloader."; type = lib.types.strMatching ''^.{8,11}$''; default = "bt-${builtins.substring 11 8 inputs.self.outPath}"; };

        builder = lib.mkOption { internal = true; type = lib.types.package; readOnly = true; };

    }; };

    config = let

        builder = (pkgs.runCommand "hermetic-${cfg.loader}" {
            outputs = [ "out" "tree" "init" ];
        } (lib.wip.substituteImplicit { inherit pkgs; scripts = [ ./hermetic-bootloader.sh ]; context = {
            inherit pkgs config inputs cfg;
            # inherit (builtins) trace;
        }; }));

    in lib.mkIf cfg.enable (lib.mkMerge [ ({

        # Set the current system as a and the default entry. This usually causes an infinite recursion (the system depending on the bootloader and vice-versa). This loop gets broken by using the special placeholder »@toplevel@«, which the installer replaces with the actual path at install time. It also supports one entry having the id »@default-self@«, renaming that to what the default id for the entry would be:
        th.hermetic-bootloader.entries.default = lib.mkOptionDefault {
            nixosConfig = config; id = "@default-self@";
            cmdline = "init=@toplevel@/init ${lib.concatStringsSep " " config.boot.kernelParams}";
        };
        th.hermetic-bootloader.default = lib.mkOptionDefault (lib.mkIf ((cfg.entries.default or null) != null) "default");

    }) ({

        # Add all specializations as entries (a specialisation »"default"« replaces the entry for the non-specialized system):
        th.hermetic-bootloader.entries = lib.mapAttrs (name: { configuration, ... }: lib.mkDefault { nixosConfig = configuration; }) config.specialisation;

    }) ({

        # Declare boot slots (all as EFI boot parts, the types will be ignored by the bootloader or overwritten when it is installed):
        wip.fs.disks.partitions = lib.wip.mapMerge (index: {
            "boot-${toString index}-${hash}" = { type = "ef00"; size = cfg.slots.size; index = index; order = 1500 - index; disk = cfg.slots.disk; }; # (ef00 = EFI boot ; 8301 = Linux reserved)
        }) (lib.range 1 cfg.slots.number);
        wip.fs.disks.devices.${cfg.slots.disk} = {
            gptOffset = cfg.extraGptOffset + (32 * (cfg.slots.number + 1)); # Make room for the slot-individual partition tables.
            allowLarger = false; # Switching the partition tables would fail if the physical disk size were to differ from the declared one.
        };

        # Mount the current boot slot:
        fileSystems."/boot" = { fsType = "vfat"; device = "/dev/disk/by-label/${cfg.slots.currentLabel}"; neededForBoot = false; options = [ "ro" "nofail" "umask=0022" ]; };

    }) ({

        th.hermetic-bootloader.builder = builder;

    }) (lib.mkIf (cfg.loader == "uboot-extlinux") {

        # https://source.denx.de/u-boot/u-boot/-/blob/v2022.04/doc/develop/distro.rst
        th.hermetic-bootloader.uboot.result = pkgs.uboot-with-mmc-env (let
            bootcmd = ''sysboot mmc ${toString cfg.uboot.mmcDev}:1 fat ''${scriptaddr} /extlinux/extlinux.conf''; # (Only) process the extlinux conf on /dev/mmc1p1:
        in {
            base = cfg.uboot.base; envMmcDev = cfg.uboot.mmcDev;
            defaultEnv = cfg.uboot.env // { inherit bootcmd; }; # How difficult it is to change the default env also shows that defining a default env per application is not really intended by uboot
            extraConfig = [
                ''CONFIG_BOOTCOMMAND="${bootcmd}"'' # While, when the same variable is defined multiple times, uboot generally uses the last definition, »env default <var>« seems to use the first (which should probably be considered a bug). To avoid inconsistency with »bootcmd«, set »CONFIG_BOOTCOMMAND«, but also define it in defaultEnv for further programmatic use.
            ] ++ cfg.uboot.extraConfig;
        });
        wip.fs.disks.partitions."uboot-env-${hash}" = {
            type = "ef02"; index = 128; order = 2000; alignment = 1;
            position = toString (cfg.uboot.result.envOffset / 512);
            size = toString (cfg.uboot.result.envSize / 512);
        };
        wip.fs.disks.postFormatCommands = "cat ${cfg.uboot.result.mkEnv { }} >/dev/disk/by-partlabel/uboot-env-${hash}\n";
        environment.etc."fw_env.config".text = "/dev/disk/by-partlabel/uboot-env-${hash} 0x0 0x${lib.concatStrings (map toString (lib.toBaseDigits 16 cfg.uboot.result.envSize))}\n";

    }) ({

        # Provide helper script to reboot into a spec:
        environment.systemPackages = [ (pkgs.writeShellScriptBin "next-boot" ''
            set -eu ; user=''${1:?'Must be the name (or unique prefix) of the specialisation to reboot into, or - for the fallback.'}
            prefix=$1 ; if [[ $1 == - ]] ; then prefix=default ; fi
            entryDir=/boot/${if config.th.hermetic-bootloader.loader == "systemd-boot" then "loader" else "extlinux"}/entries/
            entries=( $( cd $entryDir ; echo $prefix*.conf ) )
            if (( ''${#entries[@]} != 1 )) ; then echo "More than one bootloader entry has the prefix: $1" ; exit 1 ; fi
            if [[ ''${entries[0]} == "$prefix"'*'.conf ]] ; then echo "No bootloader entry has the prefix: $1" ; exit 1 ; fi
            ${if config.th.hermetic-bootloader.loader == "systemd-boot" then ''
                bootctl set-oneshot ''${entries[0]}
            '' else ''
                ${pkgs.libubootenv}/bin/fw_setenv bootcmd '${lib.concatStrings [
                    "env default bootcmd ; env save ; " # clear for next boot
                    (builtins.replaceStrings [ "/extlinux.conf" ] [ ''/entries/'"''${entries[0]}"' '' ] cfg.uboot.result.defaultEnv.bootcmd)
                ]}'
            ''}
        '') ];

    }) ({

        boot.loader.grub.enable = false;

        system.build.installBootLoader = "${builder.init} 2";
        system.boot.loader.id = "hermetic-${cfg.loader}";

    }) ]);

    # Add the additional partition table+header per boot slot.
    options.wip.fs.disks.partitioning = lib.mkOption { apply = parts: let
        esc = lib.escapeShellArg; native = pkgs.buildPackages;
        mbrOnly = cmds: if cfg.loader == "uboot-extlinux" then cmds else "";
    in pkgs.runCommand "partitioning-${config.networking.hostName}-slotted" { } ''
        set -x
        cp -aT ${parts}/ $out/ ; chmod -R +w $out
        devSize=${toString (lib.wip.parseSizeSuffix config.wip.fs.disks.devices.${cfg.slots.disk}.size)}
        name=${esc cfg.slots.disk} ; img=$name.img
        ${native.coreutils}/bin/truncate -s $devSize "$img"

        for slot in {1..${toString cfg.slots.number}} ; do
            ${native.gptfdisk}/bin/sgdisk --load-backup=$out/"$name".backup "$img" # start with the default GPT partitioning
            sgdisk=( -t $slot:ef00 ) ; for (( i = 1 ; i <= ${toString cfg.slots.number} ; i++ )) ; do # set GPT types
                (( i == slot )) || sgdisk+=( -t $i:8301 )
            done
            if [[ $slot != 1 ]] ; then sgdisk+=( --transpose=1:$slot ) ; fi # at least the OVMF EFI implementation does not respect the partition types, and tries the first partition, u-boot is also configured to use a fixed partition (1)
            ${mbrOnly ''sgdisk+=( --hybrid 1 "$img" ) # --hybrid: create MBR in addition to GPT, with GPT part 1 (formerly $slot) as MBR part 2''}
            sgdisk+=( --move-main-table=$((                 2 +      slot * 32 + ${toString cfg.extraGptOffset} )) ) # move tables so they don't conflict
            sgdisk+=( --move-backup-table=$(( devSize/512 - 1 - 32 - slot * 32 - ${toString cfg.extraGptOffset} )) )
            ${native.gptfdisk}/bin/sgdisk "''${sgdisk[@]}" "$img" # apply GPT changes

            ${mbrOnly ''printf "
                M                                # edit hybrid MBR
                d;1                              # delete parts 1 (GPT)

                # "rename" part2 as part1
                n;p;1                            # new ; primary ; part1
                $(( ($devSize/512) - 1))         # start (size 1sec)
                x;f;r                            # expert mode ; fix order ; return
                d;2                              # delete ; part2

                # create GPT part (spanning primary GPT area, no padding) as last part
                n;p;4                            # new ; primary ; part4
                1;$(( 33 + 0 ))                  # start ; end
                t;4;ee                           # type ; part4 ; GPT

                # make part1 bootable
                t;1;c                            # type ; part1 ; W95 FAT32 (LBA)
                a;1                              # active/boot ; part1

                p;w;q                            # print ; write ; quit
            " | sed -E 's/^ *| *(#.*)?$//g' | sed -E 's/\n\n+| *; */\n/g' | tee >((echo -n '++ ' ; tr $'\n' '|' ; echo) 1>&2) | ${native.util-linux}/bin/fdisk "$img"''}

            ${native.gptfdisk}/bin/sgdisk --backup=$out/"$name".slot-$slot.backup "$img"
            ${native.gptfdisk}/bin/sgdisk --print "$img" >$out/"$name".slot-$slot.gpt
            ${mbrOnly ''${native.util-linux}/bin/fdisk --type mbr --list "$img" >$out/"$name".slot-$slot.mbr''}

            # TODO: could create an additional output that only contains the sectors that the bootloader switching actually needs
        done
    ''; };

}
