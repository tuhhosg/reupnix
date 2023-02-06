dirname: inputs: { config, pkgs, lib, name, ... }: let inherit (inputs.self) lib; in { imports = [ {
    wip.preface.instances = [
        "x64" "x64-baseline" "x64-minimal"
        "arm" "arm-baseline" "arm-minimal"
    ]; # "x64-debug-withForeign" "x64-minimal-withForeign"
    wip.preface.hardware = if (lib.head (lib.splitString "-" name)) == "arm" then "aarch64" else "x86_64";
} (
    lib.th.importMachineConfig inputs dirname
) ]; }
