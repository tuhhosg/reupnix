/*

#

## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS config:
dirname: inputs: let inherit (inputs.self) lib; in pkgs: let
in {

    modules = [ ({ config, pkgs, ... }: {

        systemd.services.http = {
            serviceConfig.ExecStart = "${pkgs.busybox}/bin/httpd -f -v -p 8000 -h ${pkgs.writeTextDir "index.html" ''
                <!DOCTYPE html>
                <html><head></head><body>I'm running inside a NixOS native container</body></html>
            ''}";
            wantedBy = [ "multi-user.target" ];
            serviceConfig.Restart = "always"; serviceConfig.RestartSec = 5; unitConfig.StartLimitIntervalSec = 0;
            serviceConfig.DynamicUser = "yes";
        };

    }) ];


}
