dirname: inputs: { config, pkgs, lib, name, ... }: let lib = inputs.self.lib.__internal__; in { preface = {
    instances = [
        "x64" "x64-baseline" "x64-minimal"
        "arm" "arm-baseline" "arm-minimal"
    ]; # "x64-debug-withForeign" "x64-minimal-withForeign"
}; imports = [ (
    lib.th.importMachineConfig inputs dirname
) ]; }
