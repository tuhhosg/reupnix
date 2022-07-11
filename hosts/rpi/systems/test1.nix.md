/*

#

## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS config:
dirname: inputs: { config, pkgs, lib, name, ... }: let inherit (inputs.self) lib; in let
in { imports = [ ({ ## Hardware

    th.target.containers.enable = true;
    th.target.containers.containers.native = (
        (lib.wip.importWrapped inputs "${inputs.self}/containers/native.nix.md").required
    ) // {
        sshKeys.root = [ (lib.readFile "${inputs.self}/utils/res/ssh_dummy_1.pub") ];
        # ssh -o "IdentitiesOnly=yes" -i res/ssh_dummy_1 target -> root@native

        # ... system integration ...
    };

    th.target.containers.containers.foreign = lib.mkIf false (( # (remove the dependency on this while working on other stuff)
        (lib.wip.importWrapped inputs "${inputs.self}/containers/foreign.nix.md").required
    ) // {
        # ... system integration ...
    });

    networking.firewall.allowedTCPPorts = [ 8000 8001 ];

})  ]; }
