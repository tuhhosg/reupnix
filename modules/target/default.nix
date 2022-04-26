dirname: inputs@{ self, nixpkgs, ...}: self.lib.my.importModules inputs dirname { }
