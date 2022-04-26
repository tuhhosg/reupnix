{ description = (
    "NixOS Configuration for lightweight container systems"
    /**
     * This flake file defines the main inputs (all except for some files/archives fetched by hardcoded hash) and exports almost all usable results.
     * It should always pass »nix flake check« and »nix flake show --allow-import-from-derivation«, which means inputs and outputs comply with the flake convention.
     */
); inputs = {

    # To update »./flake.lock«: $ nix flake update
    nixpkgs = { url = "github:NixOS/nixpkgs/nixos-unstable"; }; # Upgrading from bc4b9eef3ce3d5a90d8693e8367c9cbfc9fc1e13 to fd364d268852561223a5ada15caad669fd72800e broke systemd-boot (didn't copy EFI files to /boot)

}; outputs = inputs: let patches = {

    nixpkgs = [
        ./patches/nixpkgs-test.patch
        ./patches/nixpkgs-fix-systemd-boot-install.patch
        #./patches/nixpkgs-add-specialisation-specialArgs.patch # (messing with the specialArgs could get messy, since there is no namespace isolation)
        ./patches/nixpkgs-make-bootable-optional.patch
        ./patches/nixpkgs-make-required-packages-optional.patch
    ];

}; in (import "${./.}/lib/flakes.nix" "${./.}/lib" inputs).patchFlakeInputsAndImportRepo inputs patches ./. (inputs@ { self, nixpkgs, ... }: repo@{ overlays, lib, ... }: let


in let
    systemsFlake = lib.my.mkSystemsFalke {
        #systems = { dir = "${./.}/hosts"; exclude = [ ]; };
        inherit inputs;
        scripts = [ ./utils/functions.sh ./utils/install.sh.md ];
    };

in (lib.my.forEachSystem [ "aarch64-linux" "x86_64-linux" ] (localSystem: { # And here are the outputs:
    # per architecture
    packages = /* (lib.my.getModifiedPackages (importPkgs { system = localSystem; }) overlays) // */ systemsFlake.packages.${localSystem};
    defaultPackage = systemsFlake.packages.${localSystem}.all-systems;
    apps = systemsFlake.apps.${localSystem}; devShells = systemsFlake.devShells.${localSystem};
}) // ({
    # architecture independent
    nixosConfigurations = systemsFlake.nixosConfigurations;
    inherit (repo) lib overlays overlay nixosModules nixosModule;
}))); }
