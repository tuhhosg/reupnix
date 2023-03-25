{ description = (
    "NixOS Configuration for lightweight container systems"
    /**
     * This flake file defines the main inputs (all except for some files/archives fetched by hardcoded hash) and exports almost all usable results.
     * It should always pass »nix flake check« and »nix flake show --allow-import-from-derivation«, which means inputs and outputs comply with the flake convention.
     */
); inputs = {

    # To update »./flake.lock«: $ nix flake update
    nixpkgs = { url = "github:NixOS/nixpkgs/nixos-22.11"; };
    old-nixpkgs = { url = "github:NixOS/nixpkgs/c777cdf5c564015d5f63b09cc93bef4178b19b01"; }; # 22.05 @ 2022-05-05
    new-nixpkgs = { url = "github:NixOS/nixpkgs/9370544d849be8a07193e7611d02e6f6f1b10768"; }; # 22.05 @ 2022-07-29
    wiplib = { url = "github:NiklasGollenstede/nix-wiplib"; inputs.nixpkgs.follows = "nixpkgs"; };
    nixos-imx = { url = "github:NiklasGollenstede/nixos-imx"; inputs.nixpkgs.follows = "nixpkgs"; inputs.wiplib.follows = "wiplib"; };
    nix = { url = "github:NixOS/nix/38b90c618f5ce4334b89c0124c5a54f339a23db6"; inputs.nixpkgs.follows = "nixpkgs"; inputs.nixpkgs-regression.follows = "nixpkgs"; };

}; outputs = inputs@{ wiplib, ... }: let patches = let
    base = [
        inputs.wiplib.patches.nixpkgs-test
        inputs.wiplib.patches.nixpkgs-fix-systemd-boot-install
        ./patches/nixpkgs-make-required-packages-optional.patch
    ];
in rec {

    nixpkgs = base ++ [
        ./patches/nixpkgs-make-switchable-optional.patch
    ];
    new-nixpkgs = base ++ [
        ./patches/nixpkgs-make-bootable-optional.patch
    ];
    old-nixpkgs = new-nixpkgs;

    nix = [ ./patches/nix-store-send.patch ];

}; in inputs.wiplib.lib.wip.patchFlakeInputsAndImportRepo inputs patches ./. (all-inputs@{ self, nixpkgs, ... }: repo@{ overlays, lib, ... }: let
    inputs = builtins.removeAttrs all-inputs [ "new-nixpkgs" "old-nixpkgs" ];

    # The normal build of all hosts:
    systemsFlake = lib.wip.mkSystemsFlake {
        inputs = inputs; overlayInputs = builtins.removeAttrs inputs [ "nix" ];
    };

    # All hosts cross compiled from x64 (which is irrelevant for those already x64):
    x64-systemsFlake = lib.wip.mkSystemsFlake {
        inputs = inputs; overlayInputs = builtins.removeAttrs inputs [ "nix" ];
        localSystem = "x86_64-linux";
        renameOutputs = key: "x64:${key}";
    };

    # The "normal" hosts, but built with a "new"(er) and an "old"(er) version of `nixpkgs`, for update tests:
    inherit (lib.wip.mapMerge (age: let
        age-inputs = inputs // { nixpkgs = all-inputs."${age}-nixpkgs"; };
        # Note: Any »inputs.nixpkgs.follows = "nixpkgs"« above will always point at the "current" version of »nixpkgs«. »wiplib« and »nixos-imx« use »inputs.nixpkgs.lib« (explicitly, but nothing else).
        # »repo«, which gets merged into the outputs, which are also »inputs.self«, used the new »nixpkgs« to import its stuff, so that import has to be repeated:
    in lib.wip.importRepo age-inputs ./. (repo: { "${age}-systemsFlake" = lib.wip.mkSystemsFlake rec {
        inputs = age-inputs // { self = self // repo; }; overlayInputs = builtins.removeAttrs inputs [ "nix" ];
        renameOutputs = key: "${age}:${key}";
    }; })) [ "new" "old" ]) new-systemsFlake old-systemsFlake;

in [ # Run »nix flake show --allow-import-from-derivation« to see what this merges to:
    repo systemsFlake new-systemsFlake old-systemsFlake x64-systemsFlake
    (lib.wip.forEachSystem [ "aarch64-linux" "x86_64-linux" ] (localSystem: let
        pkgs = lib.wip.importPkgs (builtins.removeAttrs inputs [ "nix" ]) { system = localSystem; };
        checks = (lib.wip.importWrapped all-inputs "${self}/checks").required pkgs;
        packages = lib.wip.getModifiedPackages pkgs overlays;
        everything = checks.packages // (lib.genAttrs [ "all-systems" "new:all-systems" "old:all-systems" ] (name: self.packages.${localSystem}.${name})); # ("x64:all-systems" doesn't quite build completely yet)
        defaultPackage = pkgs.symlinkJoin { name = "everything"; paths = builtins.attrValues everything; };
        #defaultPackage = pkgs.linkFarm "everything" everything;
    in {
        packages = packages // { default = defaultPackage; } // { nix = inputs.nix.packages.${pkgs.system}.nix; };
        checks = packages // checks.checks; inherit (checks) apps;
    }))
]); }
