{ description = (
    "NixOS Configuration for lightweight container systems"
    /**
     * This flake file defines the main inputs (all except for some files/archives fetched by hardcoded hash) and exports almost all usable results.
     * It should always pass »nix flake check« and »nix flake show --allow-import-from-derivation«, which means inputs and outputs comply with the flake convention.
     */
); inputs = {

    # To update »./flake.lock«: $ nix flake update
    nixpkgs = { url = "github:NixOS/nixpkgs/nixos-22.05"; };
    wiplib = { url = "github:NiklasGollenstede/nix-wiplib"; inputs.nixpkgs.follows = "nixpkgs"; };
    nixos-imx = { url = "github:NiklasGollenstede/nixos-imx"; inputs.nixpkgs.follows = "nixpkgs"; inputs.wiplib.follows = "wiplib"; };

    #parent = { type = "indirect"; id = "host-chain"; ref = "master"; }; # See »./modules/generations.nix.md«!
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

    systemsFlake = lib.wip.mkSystemsFlake (rec {
        #systems = { dir = "${./.}/hosts"; exclude = [ ]; };
        inherit inputs;
        overlayInputs = builtins.removeAttrs inputs [ "parent" ];
        moduleInputs = builtins.removeAttrs inputs [ "parent" "nixpkgs" ];
        scripts = (lib.attrValues lib.wip.setup-scripts) ++ [ ./utils/setup.sh ];
    });

in [ # Run »nix flake show --allow-import-from-derivation« to see what this merges to:
    repo systemsFlake
    (lib.wip.forEachSystem [ "aarch64-linux" "x86_64-linux" ] (localSystem: {
        packages = lib.wip.getModifiedPackages (lib.wip.importPkgs inputs { system = localSystem; }) overlays;
        defaultPackage = systemsFlake.packages.${localSystem}.all-systems;
    }))
]); }
