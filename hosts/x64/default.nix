dirname: inputs: { config, pkgs, lib, ... }: let inherit (inputs.self) lib; in { imports = [ {
    wip.preface.instances = [ "x64" "x64-baseline" "x64-minimal" "x64-debug-withForeign" "x64-minimal-withForeign" ];
    wip.preface.hardware = "x86_64";
} (
    lib.th.importMachineConfig inputs dirname
) ]; }
