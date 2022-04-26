/*

# Config Specialisations

Base configuration allowing for multiple specified »config.specialisations« to be bootable with virtually no overhead and without any bootloader integration.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: specialArgs@{ config, pkgs, lib, nodes, ... }: let inherit (inputs.self) lib; in let
    cfg = config.th.target.specs;
in {

    options.th = { target.specs = {
        enable = lib.mkEnableOption "bootable config specialisations";
        name = lib.mkOption { description = "Name of the current specialisation, must be the same as this spec's key the parents »config.specialisation.*« attrset."; type = lib.types.nullOr lib.types.str; default = specialArgs.specialisation or null; };
    }; };

    config = let
        hash = builtins.substring 0 8 (builtins.hashString "sha256" config.networking.hostName);

    in lib.mkIf cfg.enable (lib.mkMerge [ ({
        # Provide helper script to reboot into a spec:

        environment.systemPackages = [ (pkgs.writeShellScriptBin "boot-to" ''
            set -eu ; user=''${1:?'Must be the name of the specialisation to reboot into, or - for the fallback.'}
            ${pkgs.coreutils}/bin/mkdir -p /data ; ${pkgs.util-linux}/bin/mountpoint -q /data || /run/wrappers/bin/mount /data
            if [[ $1 == - ]] ; then
                ${pkgs.coreutils}/bin/rm -f /data/next-specialisation
            else
                printf %s $1 >/data/next-specialisation
            fi
            ${config.systemd.package}/bin/reboot
        '') ];

    }) ({
        # Make specialisations bootable:

        # $ echo test1 >data/next-specialisation
        boot.initrd.postDeviceCommands = let
            hash = builtins.substring 0 8 (builtins.hashString "sha256" config.networking.hostName);
        in lib.mkBefore ''
            # Read which next-specialisation to boot, if any. And remove the marker, so that the next reboot boots the default again, unless this boot succeeds and a next-specialisation is explicitly set again.
            mkdir /tmp/data-mnt ; mount -t ext4 /dev/disk/by-partlabel/data-${hash} /tmp/data-mnt
            if [ -e /tmp/data-mnt/next-specialisation ] ; then (
                specialisation=$(cat /tmp/data-mnt/next-specialisation)
                rm /tmp/data-mnt/next-specialisation
                printf %s "$specialisation" > /run/current-specialisation
            ) ; fi
            umount /tmp/data-mnt ; rmdir /tmp/data-mnt
        '';

        boot.initrd.postMountCommands = let
            inherit (config.system.build) extraUtils;
        in lib.mkAfter ''
            # Select to boot the current-specialisation instead of the default, if any.
            echo $stage2Init
            #setsid ${extraUtils}/bin/ash -c "exec ${extraUtils}/bin/ash < /dev/$console >/dev/$console 2>/dev/$console"
            if [ -e /run/current-specialisation ] ; then
                stage2Init=''${stage2Init%/*}/specialisation/$(cat /run/current-specialisation)/init
            fi
        '';

    }) (lib.mkIf (config.specialisation == { }) {
        # Default configuration within specialisations:

        system.nixos.tags = [ cfg.name ];
        boot.loader.enable = false; # (shared the default boot architecture)
        system.extraSystemBuilderCmds = "ln -s ${config.system.modulesTree} $out/kernel-modules"; # (disabled by »boot.loader.enable = false«)

    }) ]);

}
