/*

# System Defaults

Things that really should be (more like) this by default.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
{ config, lib, pkgs, specialisation, ... }: let
    cfg = config.th.base;
in {

    options.th = { base = {
        enable = lib.mkEnableOption "sane defaults";
    }; };

    config = let
        hash = builtins.substring 0 8 (builtins.hashString "sha256" config.networking.hostName);
        implied = true; # some mount points are implied (and forced) to be »neededForBoot« in »specialArgs.utils.pathsNeededForBoot« (this marks those here)

    in lib.mkIf cfg.enable (lib.mkMerge [ ({

        users.mutableUsers = false; users.allowNoPasswordLogin = true;
        networking.hostId = lib.mkDefault (builtins.substring 0 8 (builtins.hashString "sha256" config.networking.hostName));
        environment.etc."machine-id".text = (builtins.substring 0 32 (builtins.hashString "sha256" "${config.networking.hostName}:machine-id")); # this works, but it "should be considered "confidential", and must not be exposed in untrusted environments" (not sure _why_ though)


    }) ({
        # Robustness/debugging:

        boot.kernelParams = [ "panic=10" "boot.panic_on_fail" ]; # reboot on kernel panic, panic if boot fails
        # might additionally want to do this: https://stackoverflow.com/questions/62083796/automatic-reboot-on-systemd-emergency-mode
        systemd.extraConfig = "StatusUnitFormat=name";

    }) ]);

}
