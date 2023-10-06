/*

#

## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS config:
dirname: inputs: { config, pkgs, lib, name, ... }: let lib = inputs.self.lib.__internal__; in let
    suffix = builtins.elemAt (builtins.match ''[^-]+(-(.*))?'' name) 1;
    flags = if suffix == null then [ ] else lib.splitString "-" suffix; hasFlag = flag: builtins.elem flag flags;
in { imports = [ ({ ## Hardware

    th.target.containers.enable = true;
    th.target.containers.containers.native = (
        (lib.fun.importWrapped inputs "${inputs.self}/containers/native.nix.md").required pkgs
    ) // {
        sshKeys.root = [ (lib.readFile "${inputs.self}/utils/res/ssh_dummy_1.pub") ];
        # ssh -o "IdentitiesOnly=yes" -i res/ssh_dummy_1 target -> root@native

        # ... system integration ...
    };

    th.target.containers.containers.foreign = lib.mkIf (hasFlag "withForeign") (( # (remove the dependency on this while working on other stuff)
        (lib.fun.importWrapped inputs "${inputs.self}/containers/foreign.nix.md").required pkgs
    ) // {
        # ... system integration ...
    });

    networking.firewall.allowedTCPPorts = [ 8000 8001 ];

}) ]; }
