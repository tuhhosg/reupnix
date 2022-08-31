/*

# `nix-store-send` Stream Size

An example of the send stream, substantially updating `nixpkgs`.


## Implementation

```nix
#*/# end of MarkDown, beginning of Nix test:
dirname: inputs: pkgs: let
    inherit (inputs.self) lib;
    inherit (lib.th.testing pkgs) toplevel override unpinInputs measure-installation nix-store-send;

    new = unpinInputs inputs.self.nixosConfigurations.    "x64-minimal";
    old = unpinInputs inputs.self.nixosConfigurations."old:x64-minimal";

in ''
echo "Update stream stats (old -> new)"
cat ${nix-store-send old new ""}/stats
echo
echo "Initial image (stream null -> old)"
cat ${nix-store-send null old ""}/stats
''
