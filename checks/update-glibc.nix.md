/*

# Update `glibc`

... with a trivial change to see what update stream that creates.


## Implementation

```nix
#*/# end of MarkDown, beginning of Nix test:
dirname: inputs: pkgs: let
    inherit (inputs.self) lib;
    inherit (lib.th.testing pkgs) toplevel override unpinInputs measure-installation nix-store-send;

    base = unpinInputs inputs.self.nixosConfigurations.x64-minimal;
    old = override base { # »override« (for some reason) does not affect containers, and targeting it explicitly also doesn't work ...
        specialisation.test1.configuration.th.target.containers.containers = lib.mkForce { };
    };
    new = override old (let config = { nixpkgs.overlays = [ (final: prev: {
        glibc = prev.glibc.overrideAttrs (old: { trivialChange = 42 ; });
    }) ]; }; in config // {
        #specialisation.test1.configuration.th.target.containers.containers.native.modules = [ (_: config) ]; # this creates an infinite recursion
    });

in ''
echo "Update stream when trivially changing glibc"
: old ${toplevel old} : new ${toplevel new}
cat ${nix-store-send old new ""}/stats
''