/*

# `nix-store-send` Stream Size

An example of the send stream, substantially updating `nixpkgs`.


## Implementation

```nix
#*/# end of MarkDown, beginning of Nix test:
dirname: inputs: pkgs: let
    lib = inputs.self.lib.__internal__;
    test = lib.th.testing pkgs;

    new = test.unpinInputs inputs.self.nixosConfigurations."new:x64-minimal";
    old = test.unpinInputs inputs.self.nixosConfigurations."old:x64-minimal";

in ''
echo "Update stream stats (old -> new)"
cat ${test.nix-store-send old new ""}/stats
echo
echo "Initial image (stream null -> old)"
cat ${test.nix-store-send null old ""}/stats
''
