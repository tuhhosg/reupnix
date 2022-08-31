{ description = (
    "NixOS Configuration for lightweight container systems"
    /**
     * This flake file defines the main inputs (all except for some files/archives fetched by hardcoded hash) and exports almost all usable results.
     * It should always pass »nix flake check« and »nix flake show --allow-import-from-derivation«, which means inputs and outputs comply with the flake convention.
     */
); inputs = {

    # To update »./flake.lock«: $ nix flake update
    nixpkgs = { url = "github:NixOS/nixpkgs/nixos-22.05"; };
    old-nixpkgs = { url = "github:NixOS/nixpkgs/c777cdf5c564015d5f63b09cc93bef4178b19b01"; };
    wiplib = { url = "github:NiklasGollenstede/nix-wiplib"; inputs.nixpkgs.follows = "nixpkgs"; };
    nixos-imx = { url = "github:NiklasGollenstede/nixos-imx"; inputs.nixpkgs.follows = "nixpkgs"; inputs.wiplib.follows = "wiplib"; };

    #parent = { type = "indirect"; id = "host-chain"; ref = "master"; }; # See »./modules/generations.nix.md«!
    # inputs.self.shortRev is only set if the git tree is clean (?)

}; outputs = inputs@{ wiplib, ... }: let patches = rec {

    nixpkgs = [
        inputs.wiplib.patches.nixpkgs-test
        inputs.wiplib.patches.nixpkgs-fix-systemd-boot-install
        #./patches/nixpkgs-add-specialisation-specialArgs.patch # (messing with the specialArgs could get messy, since there is no namespace isolation)
        ./patches/nixpkgs-make-bootable-optional.patch
        ./patches/nixpkgs-make-required-packages-optional.patch
    ];
    old-nixpkgs = nixpkgs;

}; in inputs.wiplib.lib.wip.patchFlakeInputsAndImportRepo inputs patches ./. (inputs@{ self, nixpkgs, ... }: repo@{ overlays, lib, ... }: let

    # The normal build of all hosts:
    systemsFlake = lib.wip.mkSystemsFlake {
        inputs = builtins.removeAttrs inputs [ "old-nixpkgs" ];
    };

    # All hosts cross compiled from x64 (which is irrelevant for those already x64):
    x64-systemsFlake = lib.wip.mkSystemsFlake {
        inputs = builtins.removeAttrs inputs [ "old-nixpkgs" ];
        localSystem = "x86_64-linux";
        renameOutputs = key: "x64:${key}";
    };

    # The "normal" hosts, but built with an older version of `nixpkgs`, for update tests:
    old-systemsFlake = let
        old-inputs = (builtins.removeAttrs inputs [ "old-nixpkgs" ]) // { nixpkgs = inputs.old-nixpkgs; };
        # »repo«, which gets merged into the outputs, which are also »inputs.self«, used the new »nixpkgs« to import its stuff, so that import has to be repeated:
    in lib.wip.importRepo old-inputs ./. (repo: lib.wip.mkSystemsFlake {
        inputs = old-inputs // { self = self // repo; };
        renameOutputs = key: "old:${key}";
    });

in [ # Run »nix flake show --allow-import-from-derivation« to see what this merges to:
    repo systemsFlake old-systemsFlake x64-systemsFlake
    (lib.wip.forEachSystem [ "aarch64-linux" "x86_64-linux" ] (localSystem: rec {
        packages = lib.wip.getModifiedPackages (lib.wip.importPkgs inputs { system = localSystem; }) overlays;
        defaultPackage = self.packages.${localSystem}.all-systems; checks = packages;
    }))
    (lib.wip.forEachSystem [ "aarch64-linux" "x86_64-linux" ] (localSystem: {
        inherit ((lib.wip.importWrapped inputs "${self}/checks").required (lib.wip.importPkgs inputs { system = localSystem; })) checks apps;
    }))
]); }
