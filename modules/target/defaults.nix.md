/*

# Target Device Config Defaults

Base configuration for the target devices, pulling in everything that all target devices should have in common.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: { config, pkgs, lib, ... }: let inherit (inputs.self) lib; in let
    cfg = config.th.target.defaults;
in {

    options.th = { target.defaults = {
        enable = lib.mkEnableOption "base configuration for the target devices. This would usually be enabled by importing the result of calling »lib.th.importMachine«";
    }; };

    config = let
        hash = builtins.substring 0 8 (builtins.hashString "sha256" config.networking.hostName);
    in lib.mkIf cfg.enable (lib.mkMerge [ ({

        wip.base.enable = true;
        th.hermetic-bootloader.enable = true;
        th.target.fs.enable = true;
        th.target.specs.enable = true;
        th.minify.enable = true; th.minify.etcAsOverlay = true;
        wip.services.dropbear.enable = true;

        documentation.enable = false; # sometimes takes quite long to build
        boot.loader.timeout = 1;

    }) ]);

}
