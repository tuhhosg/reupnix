/*

# Generation Chaining

The idea ist to have a flake input `parent` that points to the same repository and branch. After each commit, that input gets updated to point at the new commit. If deployments only happen after the commit and update, then the chain of `parent` inputs recursively forms the list of all states ever deployed. The `flake.lock` automatically captures that dependency graph, and since it is itself part of any previous commit, one could even call this a blockchain.

For the `parent` input to be able to point back to this repository (without needing to publish each and every commit immediately), an entry in `~/.config/nix/registry.json` is required:
```json
{ "version": 2, "flakes": [ {
    "from": { "type": "indirect", "id": "host-chain" },
    "to": {  "type": "git", "url": "file:///absolute/path/to/this/repo" }
} ] }
```

Using the chain of `parent`s, states spanning more than one config generation and updates between them can be expressed in the NixOS config and evaluated hermetically.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: { config, pkgs, lib, name, ... }: let inherit (inputs.self) lib; in let
    cfg = config.th.generations;
    parents = let
        addParents = inputs: list: if inputs?parent then [ inputs.parent ] ++ (addParents inputs.parent.inputs list) else list;
    in addParents inputs [ ];
    closure = pkgs.runCommandLocal "systems-closure" { } ''
        mkdir -p $out
        ln -sT ${config.system.build.toplevel} $out/current
        ${lib.concatStringsSep "\n" (lib.imap1 (index: package: (let
            outputs = (import "${package}/flake.nix").outputs ({ self = package // outputs; } // package.inputs);
        in (
            "ln -sT ${outputs.nixosConfigurations.${name}.config.system.build.toplevel} $out/parent-${toString index}"
        ))) parents)}
    '';
    parentClosure = let
        package = lib.head parents;
        outputs = (import "${package}/flake.nix").outputs ({ self = package // outputs; } // package.inputs);
    in if ((lib.length parents) > 0) && outputs.nixosConfigurations?${name} then (
        outputs.nixosConfigurations.${name}.config.th.generations.closure
    ) else null;

in {

    options.th = { generations = {
        keepPrevious = lib.mkOption {
            description = "Number of previous configurations to include in this generation's closure. Do not reach back further than the current system is actually defined.";
            type = lib.types.ints.between 0 (lib.length parents); default = let len = lib.length parents; in if len >= 2 then 2 else len;
        };
        parents = lib.mkOption {
            description = "All parents of this configuration, as list of flake input packages.";
            type = lib.types.listOf lib.types.package; readOnly = true; default = parents;
        };
        closure = lib.mkOption {
            description = "A closure package including this plus ».keepPrevious« parent generations.";
            type = lib.types.package; readOnly = true; default = closure;
        };
        parentClosure = lib.mkOption {
            description = "The ».closure« of the parent (previous generation).";
            type = lib.types.nullOr lib.types.package; readOnly = true; default = parentClosure;
        };
    }; };

}
