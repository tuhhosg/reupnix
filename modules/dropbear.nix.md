/*

# Dropbear SSHd Configuration

OpenSSH adds ~35MB closure size. Let's try `dropbear` instead!


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
{ config, lib, pkgs, ... }: let
    cfg = config.th.dropbear;
in {

    options.th = { dropbear = {
        enable = lib.mkEnableOption "dropbear SSH daemon";
        socketActivation = lib.mkEnableOption "socket activation mode for dropbear";
        rootKeys = lib.mkOption { default = [ ]; type = lib.types.listOf lib.types.str; description = "Literal lines to write to »/root/.ssh/authorized_keys«"; };
    }; };

    config = lib.mkIf cfg.enable (lib.mkMerge [ ({
        environment.systemPackages = (with pkgs; [ dropbear ]);

        networking.firewall.allowedTCPPorts = [ 22 ];
        environment.etc."dropbear/.mkdir".text = "";

    }) (lib.mkIf (!cfg.socketActivation) {

        systemd.services."dropbear" = {
            description = "dropbear SSH server (listening)";
            wantedBy = [ "multi-user.target" ]; after = [ "network.target" ];
            serviceConfig.ExecStart = lib.concatStringsSep "" [
                "${pkgs.dropbear}/bin/dropbear"
                " -F -E" # don't fork, use stderr
                " -p 22" # handle a single connection on stdio
                " -R" # generate host keys on connection
                #" -r .../dropbear_rsa_host_key"
            ];
            #serviceConfig.PIDFile = "/var/run/dropbear.pid"; serviceConfig.Type = "forking"; after = [ "network.target" ]; # alternative to »-E -F« (?)
        };

    }) (lib.mkIf (cfg.socketActivation) {

        # This did not work: dropbear errors out with "socket operation on non-socket".

        systemd.sockets.dropbear = { # start a »dropbear@.service« on any number of TCP connections on port 22
            conflicts = [ "dropbear.service" ];
            listenStreams = [ "22" ];
            socketConfig.Accept = true;
            wantedBy = [ "sockets.target" ]; # (isn't this implicit?)
        };
        systemd.services."dropbear@" = {
            description = "dropbear SSH server (per-connection)";
            after = [ "syslog.target" ];
            serviceConfig.ExecStart = lib.concatStringsSep "" [
                "-"  # for the most part ignore exit != 0
                "${pkgs.dropbear}/bin/dropbear"
                " -i" # handle a single connection on stdio
                " -R" # generate host keys on connection
                #" -r .../dropbear_rsa_host_key"
            ];
        };

    }) (lib.mkIf (cfg.rootKeys != [ ]) {

        system.activationScripts.root-authorized_keys = ''
            mkdir -pm 700 /root/.ssh/
            [ -e /root/.ssh/authorized_keys ] || install -m 600 -T /dev/null /root/.ssh/authorized_keys
            chmod 600 /root/.ssh/authorized_keys
            ${lib.concatMapStringsSep "\n" (key: "printf %s ${lib.escapeShellArg key} >>/root/.ssh/authorized_keys") cfg.rootKeys}
        '';

    }) ]);

}
