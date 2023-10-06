dirname: inputs@{ nixpkgs, functions, installer, wiplib, ...}: let
    categories = functions.lib.importAll inputs dirname;
    self = (builtins.foldl' (a: b: a // (if builtins.isAttrs b && ! b?__functor then b else { })) { } (builtins.attrValues categories)) // categories;
in self // { __internal__ = nixpkgs.lib // { th = self; fun = functions.lib; inst = installer.lib; wip = wiplib.lib; }; }
