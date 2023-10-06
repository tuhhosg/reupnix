dirname: inputs@{ self, nixpkgs, ...}: self.lib.__internal__.fun.importModules inputs dirname { }
