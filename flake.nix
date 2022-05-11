{ description = (
    "NixOS Configuration for lightweight container systems"
    /**
     * This flake file defines the main inputs (all except for some files/archives fetched by hardcoded hash) and exports almost all usable results.
     * It should always pass »nix flake check« and »nix flake show --allow-import-from-derivation«, which means inputs and outputs comply with the flake convention.
     */
); inputs = {

    # To update »./flake.lock«: $ nix flake update
    nixpkgs = { url = "github:NixOS/nixpkgs/nixos-unstable"; };
    wiplib = { url = "github:NiklasGollenstede/nix-wiplib"; };

    #parent = { type = "indirect"; id = <something that resolves to this repo>; };
    # inputs.self.shortRev is only set if the git tree is clean (?)

}; outputs = inputs@{ wiplib, ... }: let patches = {

    nixpkgs = [
        inputs.wiplib.patches.nixpkgs-test
        inputs.wiplib.patches.nixpkgs-fix-systemd-boot-install
        #./patches/nixpkgs-add-specialisation-specialArgs.patch # (messing with the specialArgs could get messy, since there is no namespace isolation)
        ./patches/nixpkgs-make-bootable-optional.patch
        ./patches/nixpkgs-make-required-packages-optional.patch
    ];

}; in inputs.wiplib.lib.wip.patchFlakeInputsAndImportRepo inputs patches ./. (inputs@{ self, nixpkgs, ... }: repo@{ overlays, lib, ... }: let

    systemsFlake = lib.wip.mkSystemsFalke (rec {
        #systems = { dir = "${./.}/hosts"; exclude = [ ]; };
        inherit inputs;
        overlayInputs = builtins.removeAttrs inputs [ "parent" ];
        moduleInputs = builtins.removeAttrs inputs [ "parent" "nixpkgs" ];
        scripts = [ ./utils/install.sh.md ] ++ (lib.attrValues lib.wip.setup-scripts);
    });

in [ # Run »nix flake show --allow-import-from-derivation« to see what this merges to:
    repo systemsFlake
    (lib.wip.forEachSystem [ "aarch64-linux" "x86_64-linux" ] (localSystem: {
        packages = lib.wip.getModifiedPackages (lib.wip.importPkgs inputs { system = localSystem; }) overlays;
        defaultPackage = systemsFlake.packages.${localSystem}.all-systems;
    }))
]); }
