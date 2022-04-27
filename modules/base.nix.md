/*

# System Defaults

Things that really should be (more like) this by default.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: { config, pkgs, lib, ... }: let inherit (inputs.self) lib; in let
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

    }) ({
        # Free convenience:

        # The non-interactive version of bash does not remove »\[« and »\]« from PS1. Seems to work just fine without those. So make the prompt pretty (and informative):
        programs.bash.promptInit = ''
            # Provide a nice prompt if the terminal supports it.
            if [ "''${TERM:-}" != "dumb" ] ; then
                if [[ "$UID" == '0' ]] ; then if [[ ! "''${SUDO_USER:-}" ]] ; then # direct root: red username + green hostname
                    PS1='\e[0m\e[48;5;234m\e[96m$(printf "%-+ 4d" $?)\e[93m[\D{%Y-%m-%d %H:%M:%S}] \e[91m\u\e[97m@\e[92m\h\e[97m:\e[96m\w'"''${TERM_RECURSION_DEPTH:+\e[91m["$TERM_RECURSION_DEPTH"]}"'\e[24;97m\$ \e[0m'
                else # sudo root: red username + red hostname
                    PS1='\e[0m\e[48;5;234m\e[96m$(printf "%-+ 4d" $?)\e[93m[\D{%Y-%m-%d %H:%M:%S}] \e[91m\u\e[97m@\e[91m\h\e[97m:\e[96m\w'"''${TERM_RECURSION_DEPTH:+\e[91m["$TERM_RECURSION_DEPTH"]}"'\e[24;97m\$ \e[0m'
                fi ; else # other user: green username + green hostname
                    PS1='\e[0m\e[48;5;234m\e[96m$(printf "%-+ 4d" $?)\e[93m[\D{%Y-%m-%d %H:%M:%S}] \e[92m\u\e[97m@\e[92m\h\e[97m:\e[96m\w'"''${TERM_RECURSION_DEPTH:+\e[91m["$TERM_RECURSION_DEPTH"]}"'\e[24;97m\$ \e[0m'
                fi
                if test "$TERM" = "xterm" ; then
                    PS1="\033]2;\h:\u:\w\007$PS1"
                fi
            fi
            export TERM_RECURSION_DEPTH=$(( 1 + ''${TERM_RECURSION_DEPTH:-0} ))
        '';

    }) ]);

}
