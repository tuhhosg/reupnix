/*

Fixes for stuff that doesn't build (when cross-compiling or building through qemu).


## Implementation

```nix
#*/# end of MarkDown, beginning of NixPkgs overlay:
dirname: inputs: final: prev: let
    inherit (final) pkgs; inherit (inputs.self) lib;
    pkgsVersion = lib.fileContents "${pkgs.path}/.version"; # (there is probably some better way to get this)
in {

    # These do tests that expect certain program crash behavior, which is slightly different when run via qemu-user:
    mdbook = prev.mdbook.overrideAttrs (old: lib.optionalAttrs (pkgs.system == "aarch64-linux") {
        doCheck = false;
    });
    nix = prev.nix.overrideAttrs (old: lib.optionalAttrs (pkgs.system == "aarch64-linux") {
        doInstallCheck = false;
    });


    # No idea why these fail:
    libxml2 = prev.libxml2.overrideAttrs (old: {
        doCheck = false; # at least one of the errors is "Unsupported encoding ISO-8859-5" (but even without stripping glibc)
    });
    man-db = prev.man-db.overrideAttrs (old: {
        doCheck = false;
    });
    perl536 = prev.perl536.overrideAttrs (old: lib.optionalAttrs (pkgsVersion == "22.11") {
        passthru = old.passthru // { pkgs = old.passthru.pkgs.override {
            # (this effectively disables config.nixpkgs.config.perlPackageOverrides)
            overrides = (_: {
                Po4a = (lib.recurseIntoAttrs prev.perl536.pkgs).Po4a.overrideAttrs (old: {
                    doCheck = false;
                });
            });
        }; };
    }); # ((yes, this verbose monster seems about the most "at the root" way to override perl packages (but still only for one version of perl)))

/*
    # And these failed at some point, but now don't?
    libuv = prev.libuv.overrideAttrs (old: {
        doCheck = false; # failing: tcp_bind6_error_addrinuse tcp_bind_error_addrinuse_connect tcp_bind_error_addrinuse_listen
    });
    openssh = prev.openssh.overrideAttrs (old: {
        doCheck = false;
    });
    orc = prev.orc.overrideAttrs (old: lib.optionalAttrs (pkgsVersion == "22.11") {
        doCheck = false;
    });
 */

}
