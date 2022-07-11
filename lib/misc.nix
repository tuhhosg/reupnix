dirname: { self, nixpkgs, wiplib, ...}: let
    inherit (nixpkgs) lib;
    inherit (wiplib.lib.wip) importWrapped getNamedNixFiles;
in rec {

    ## From a host's »default.nix«, import the »machine.nix« configuration, any »systems/« configurations, and enable the defaults for target devices.
    # The reason why this is a library function and not part of the ../target/defaults module is that importing based on a parameter (»dirname«) does not work with NixOS' module system.
    importMachine = inputs: dirname: {
        th.target.defaults.enable = true;
        imports = [ (importWrapped inputs "${dirname}/machine.nix").module ];
        specialisation = lib.mapAttrs (name: path: { configuration = {
            th.target.specs.name = name;
            imports = [ (importWrapped inputs path).module ];
        }; }) (getNamedNixFiles "${dirname}/systems" [ ]);
    };

}
