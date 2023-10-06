dirname: inputs: { config, pkgs, lib, name, ... }: let lib = inputs.self.lib.__internal__; in { preface = {
    instances = [
        "imx" "imx-baseline" "imx-minimal"
    ];
}; imports = [ (
    lib.th.importMachineConfig inputs dirname
) ]; }
