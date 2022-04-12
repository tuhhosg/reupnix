/*

# Generic Setup

General setup related things. Let's see ...


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
{ config, lib, pkgs, ... }: let
    cfg = config.th.setup;
in {

    options.th = { setup = {
        #enable = lib.mkEnableOption "";
        imageSize = lib.mkOption { description = "The size of the image to create, when installing to an image, as argument to »fallocate -l«."; type = lib.types.str; default = "8G"; };
        hostHash = lib.mkOption { description = "SHA256 hash of the »config.networking.hostName«, prefixes of this are used as fixed-length host identifiers for partitions and such."; type = lib.types.str; default = (builtins.hashString "sha256" config.networking.hostName); readOnly = true; };
    }; };

   #config = lib.mkIf cfg.enable (lib.mkMerge [ ({
   #}) ]);

}
