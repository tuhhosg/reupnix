dirname: inputs@{ self, nixpkgs, ...}: let
    #fix = f: let x = f x; in x;
    #categories = fix (th: (import "${dirname}/imports.nix" dirname inputs).importAll (inputs // { self = inputs.self // { lib = nixpkgs.lib // { inherit th; }; }; })) dirname;
    categories = inputs.wiplib.lib.wip.importAll inputs dirname;
    th = (builtins.foldl' (a: b: a // b) { } (builtins.attrValues (builtins.removeAttrs categories [ "testing" ]))) // categories;
in nixpkgs.lib // { inherit th; inherit (inputs.wiplib.lib) wip; }
