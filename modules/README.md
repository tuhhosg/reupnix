
# NixOS Modules

A NixOS module is a collection of any number of NixOS option definitions and value assignments to those or other options.
While the set of imported modules and thereby defined options is static (in this case starting with the modules passed to `mkNixosSystem` in `../flake.nix`), the value assignments can generally be contingent on other values (as long as there are no logical loops), making for a highly flexible system construction.
Since modules can't be imported (or excluded) dynamically, most modules have an `enable` option, which, if false, effectively disables whatever that module does.

Ultimately, the goal of a NixOS configuration is to build an operating system, which is basically a structured collection of program and configuration files.
To that end, there are a number of pre-defined options (in `nixpkgs`) that collect programs, create and write configuration files (primarily in `/etc`), compose a boot loader, etc.
Other modules use those options to manipulate how the system is built.


## Template

Here is a skeleton structure for writing a new `<module>.nix.md`:

````md
/*

# TODO: title

TODO: documentation

## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
{ config, lib, pkgs, ... }: let
    cfg = config.th.${TODO: name};
in {

    options.th = { ${TODO: name} = {
        enable = lib.mkEnableOption "TODO: what";
        # TODO: more options
    }; };

    config = lib.mkIf cfg.enable (lib.mkMerge [ ({
        # TODO: implementation
    }) ]);

}
````
