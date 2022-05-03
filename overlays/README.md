
# NixOS Overlays

Nix(OS) manages its packages in a global attribute set, mostly referred to as `nixpkgs` (as repository/sources) or simply as `pkgs` (when evaluated).

Overlays are a mechanism to add or replace packages in that attribute set, such that wherever else they are referenced (e.g. as `pkg.<package>`) the added/replaced version is used.

Any number of overlays can be applied in sequence when instantiating/evaluating `nixpkgs` into `pkgs`.
Each overlay is a function with two parameters returning an attrset which is merged onto `pkgs`.
The first parameter (called `final`) is the `pkgs` as it will result after applying all overlays. This works because of nix's lazy evaluation, but accessing attributes that are based on the result of the current overlay will logically cause unresolvable recursions.
For that reason, the second parameter `prev` is the version of `pkgs` from before applying the overlay.
As a general guideline, use `final` where possible (to avoid consuming unpatched packages) and `prev` only when necessary to avoid recursions.

`prev` thus gives access to the packages being overridden and allows (the build instructions for) the overriding package to be based off the unmodified package.
Most packages in `nixpkgs` are constructed using something like `callPackage ({ ...args }: mkDerivation { ...attributes }) { ...settings }`, where `callPackage` is usually in `all-packages.nix` and imports the code in the parentheses from a different file.
Passed by `callPackage`, `args` includes `pkgs` plus optionally the `settings` to the package.
The `attributes` are then based on local values and packages and settings from `args`.
Any package built that way then has two functions which allow overlays (or code elsewhere) to define modified versions of that package:
* `.overwrite` is a function taking an attrset that is merged over `args` before re-evaluation the package;
* `.overrideAttrs` is a function from the old `attributes` to ones that are merged over `attributes` before building the derivation.

Using the above mechanisms, each file in this folder adds and/or modifies one or more packages to/in `pkgs`.
[`./default.nix`](./default.nix) exports all overlays as an attribute set; [`flake#outputs.packages.<arch>.*`](../flake.nix), exports all packages resulting from the overlays.


## Template/Examples

Here is a skeleton structure / collection of examples for writing a new `<overlay>.nix.md`:

````md
/*

# TODO: title

TODO: documentation

## Implementation

```nix
#*/# end of MarkDown, beginning of NixPkgs overlay:
dirname: inputs: final: prev: let
    inherit (final) pkgs; inherit (inputs.self) lib;
in {

    # e.g.: add a patched version of a package (use the same name to replace)
    systemd-patched = prev.systemd.overrideAttrs (old: {
        patches = (old.patches or [ ]) ++ [
            ../patches/systemd-....patch
        ];
    });

    # e.g.: add a prebuilt program as package
    qemu-aarch64-static = pkgs.stdenv.mkDerivation {
        name = "qemu-aarch64-static";
        src = builtins.fetchurl {
            url = "https://github.com/multiarch/qemu-user-static/releases/download/v6.1.0-8/qemu-aarch64-static";
            sha256 = "075l122p3qfq6nm07qzvwspmsrslvrghar7i5advj945lz1fm6dd";
        }; dontUnpack = true;
        installPhase = "install -D -m 0755 $src $out/bin/qemu-aarch64-static";
    };

    # e.g.: update (or pin the version of) a package
    raspberrypifw = prev.raspberrypifw.overrideAttrs (old: rec {
        version = "1.20220308";
        src = pkgs.fetchFromGitHub {
            owner = "raspberrypi"; repo = "firmware"; rev = version;
            sha256 = "sha256-pwhI9sklAGq5+fJqQSadrmW09Wl6+hOFI/hEewkkLQs=";
        };
    });

    # e.g.: add a program as new package
    udptunnel = pkgs.stdenv.mkDerivation rec {
        pname = "udptunnel"; version = "1"; # (not versioned)

        src = pkgs.fetchFromGitHub {
            owner = "rfc1036"; repo = pname; rev = "482ed94388a0dde68561584926c7d5c14f079f7e"; # 2018-11-18
            sha256 = "1wkzzxslwjm5mbpyaq30bilfi2mfgi2jqld5l15hm5076mg31vp7";
        };
        patches = [ ../patches/....patch ];

        installPhase = ''
            mkdir -p $out/bin $out/share/udptunnel
            cp -T udptunnel $out/bin/${pname}
            cp COPYING $out/share/udptunnel
        '';

        meta = {
            homepage = "https://github.com/rfc1036/udptunnel";
            description = "Tunnel UDP packets in a TCP connection ";
            license = lib.licenses.gpl2;
            maintainers = with lib.maintainers; [ ];
            platforms = with lib.platforms; linux;
        };
    };
}
````
