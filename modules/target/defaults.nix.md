/*

# Target Device Config Defaults

Base configuration for the target devices, pulling in everything that all target devices should have in common.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: moduleArgs@{ config, pkgs, lib, ... }: let lib = inputs.self.lib.__internal__; in let
    cfg = config.th.target.defaults;
in {

    options.th = { target.defaults = {
        enable = lib.mkEnableOption "base configuration for the target devices. This would usually be enabled by importing the result of calling »lib.th.importMachine«";
    }; };

    config = let
        hash = builtins.substring 0 8 (builtins.hashString "sha256" config.networking.hostName);
    in lib.mkIf cfg.enable (lib.mkMerge [ ({

        ## Enable modules:
        wip.base.enable = true; wip.base.autoUpgrade = false;
        th.hermetic-bootloader.enable = true;
        th.target.fs.enable = true;
        th.target.specs.enable = true;
        th.minify.enable = true; th.minify.etcAsOverlay = true;
        wip.services.dropbear.enable = true;
        th.target.watchdog.enable = true;

        ## Convenience:
        documentation.enable = false; # sometimes takes quite long to build
        boot.loader.timeout = 1;

    }) ]);

}
