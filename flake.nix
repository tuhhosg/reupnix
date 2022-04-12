{ description = (
    "NixOS Configuration for lightweight container systems"
    /**
     * This flake file defines the main inputs (all except for some files/archives fetched by hardcoded hash) and exports almost all usable results.
     * It should always pass »nix flake check« and »nix flake show --allow-import-from-derivation«, which means inputs and outputs comply with the flake convention.
     * For convenience, it additionally has an output »lib« exporting »./utils/lib.nix«.
     */
); inputs = {

    # To update »./flake.lock«: $ nix flake update
    nixpkgs = { url = "github:NixOS/nixpkgs/nixos-unstable"; }; # Upgrading from bc4b9eef3ce3d5a90d8693e8367c9cbfc9fc1e13 to fd364d268852561223a5ada15caad669fd72800e broke systemd-boot (didn't copy EFI files to /boot)

}; outputs = inputs: let patches = {

    nixpkgs = [
        ./patches/nixpkgs-test.patch
        ./patches/nixpkgs-fix-systemd-boot-install.patch
        ./patches/nixpkgs-add-specialisation-specialArgs.patch
        ./patches/nixpkgs-make-bootable-optional.patch
        ./patches/nixpkgs-make-required-packages-optional.patch
    ];

}; in (import ./utils/lib.nix).patchFlakeInputs inputs patches (inputs@ { self, nixpkgs, ... }: let # (the return value is »inputs.self«)

    forceAarch64Cross = false; # Assume current host is x64 and force cross-compiling aarch64 (instead of using qemu). Cross-compiling the entire systems often fails, but for individual packages (say the kernel) this is much faster than "natively" building through qemu. (Obviously this is a hack and only makes sense to temporarily set when building on an x64 system. Can this (with `--impure`) be made an env var?) # TODO: While this works to build things, nix does not use them in consecutive builds without this flag, which make it rather pointless.

    overlays = import "${./.}/overlays"; modules = import "${./.}/modules";
    lib = nixpkgs.lib // { th = import ./utils/lib.nix; };

    nixpkgsConfig.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ ]; # this can probably stay empty

    importPkgs = { system, ... }: let
        localSystem = if forceAarch64Cross then "x86_64-linux" else system;
        pkgs = (import nixpkgs { system = localSystem; overlays = builtins.attrValues overlays; config = nixpkgsConfig; });
    in if forceAarch64Cross && system == "aarch64-linux" then pkgs.pkgsCross.aarch64-multiplatform else pkgs;


in let
    systemsFlake = lib.th.mkSystemsFalke {
        systems = { dir = "${./.}/hosts"; exclude = [ ]; };
        specialArgs = { inherit lib inputs; specialisation = null; }; # »specialisation« to be overridden by specialisations
        modules = builtins.attrValues modules;
        inherit importPkgs inputs; configPath = ./.;
        scripts = [ ./utils/functions.sh ./utils/install.sh.md ];
    };

in (lib.th.forEachSystem [ "aarch64-linux" "x86_64-linux" ] (localSystem: { # And here are the outputs:
    # per architecture
    packages = (lib.th.getModifiedPackages (importPkgs { system = localSystem; }) overlays) // systemsFlake.packages.${localSystem};
    defaultPackage = systemsFlake.packages.${localSystem}.all-systems;
    apps = systemsFlake.apps.${localSystem}; devShells = systemsFlake.devShells.${localSystem};
}) // ({
    # architecture independent
    nixosConfigurations = systemsFlake.nixosConfigurations; lib = lib.th;
    overlays = overlays; overlay = final: prev: builtins.foldl' (prev: overlay: overlay final prev) prev (builtins.attrValues overlays); # (I think this should work)
    nixosModules = modules; nixosModule = { imports = builtins.attrValues modules; };
}))); }
