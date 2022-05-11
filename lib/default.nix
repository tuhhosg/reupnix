dirname: inputs@{ self, nixpkgs, ...}: let
    #fix = f: let x = f x; in x;
    #categories = fix (my: (import "${dirname}/imports.nix" dirname inputs).importAll (inputs // { self = inputs.self // { lib = nixpkgs.lib // { inherit my; }; }; })) dirname;
    categories = (import "${dirname}/imports.nix" dirname inputs).importAll inputs dirname;
    my = (builtins.foldl' (a: b: a // b) { } (builtins.attrValues categories)) // categories;
in nixpkgs.lib // { inherit my; inherit (inputs.wiplib.lib) wip; }
