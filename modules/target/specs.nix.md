/*

# Config Specialisations

Base configuration allowing for multiple specified »config.specialisations« to be bootable with virtually no overhead and without any bootloader integration.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: specialArgs@{ config, pkgs, lib, nodes, ... }: let lib = inputs.self.lib.__internal__; in let
    cfg = config.th.target.specs;
in {

    options.th = { target.specs = {
        enable = lib.mkEnableOption "bootable config specialisations";
        name = lib.mkOption { description = "Name of the current specialisation, must be the same as this spec's key the parents »config.specialisation.*« attrset."; type = lib.types.nullOr lib.types.str; default = specialArgs.specialisation or null; };
    }; };

    config = let
        hash = builtins.substring 0 8 (builtins.hashString "sha256" config.networking.hostName);

    in lib.mkIf cfg.enable (lib.mkMerge [ ({
        # Default specialization:

        specialisation.default.configuration = {
            th.target.specs.name = "default";

            # Enable receiving of updates:
            environment.systemPackages = [ pkgs.nix-store-recv ];

            environment.etc.dummy.text = "mega significant change in configuration\n";
            #environment.etc.dummy.text = "super significant change in configuration\n";

            # Test the updating:
            # * switch the dummy files or make some other detectable change
            # * run in the repo: nix run .#nix-store-send -- $(ssh imx -- cat /boot/toplevel) $(nix build .#nixosConfigurations.imx.config.system.build.toplevel --print-out-paths) --stats | ssh imx -- nix-store-recv --no-delete --status --verbose
            # * run in the repo: ssh imx -- nix-store-recv --only-delete --status --verbose

        };

        # Replace the default bootloader entry (which would be the machine config) with the default(/fallback) system config:
        th.hermetic-bootloader.default = "default";

        # In the "machine config" (only), include the bootloader installer (which then references all the system configs):
        system.extraSystemBuilderCmds = lib.mkIf (config.specialisation != { }) ''
            printf '#!%s/bin/bash -e\nexec %s $1 %s\n' "${pkgs.bash}" "${config.th.hermetic-bootloader.builder}" "$out" >$out/install-bootloader
            chmod +x $out/install-bootloader
        '';


    }) (lib.mkIf (config.specialisation == { } && cfg.name != null) {
        # Config within a specialisation only:

        system.nixos.tags = [ cfg.name ];
        system.extraSystemBuilderCmds = ''rm -f $out/initrd'';

    }) (lib.mkIf (config.specialisation != { }) {
        # Config outside the specialisations only:

    }) ]);

}
