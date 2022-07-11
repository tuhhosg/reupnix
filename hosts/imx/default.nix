dirname: inputs: { config, pkgs, lib, name, ... }: let inherit (inputs.self) lib; in { imports = [ {
    #wip.preface.instances = [ ... ];
    wip.preface.hardware = "aarch64";
} (
    lib.th.importMachine inputs dirname
) ]; }
