dirname: inputs: { config, pkgs, lib, name, ... }: let inherit (inputs.self) lib; in { imports = [ {
    wip.preface.instances = [ "rpi" "rpi-baseline" "rpi-minimal" ];
    wip.preface.hardware = "aarch64";
} (
    lib.th.importMachineConfig inputs dirname
) ]; }
