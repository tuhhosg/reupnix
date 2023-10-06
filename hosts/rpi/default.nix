dirname: inputs: { config, pkgs, lib, name, ... }: let lib = inputs.self.lib.__internal__; in { preface = {
    instances = [
        "rpi" "rpi-baseline" "rpi-minimal"
    ];
}; imports = [ (
    lib.th.importMachineConfig inputs dirname
) ]; }
