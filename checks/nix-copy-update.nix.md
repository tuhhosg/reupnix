/*

# Update via `nix-store-send`

An example of the send stream, substantially updating `nixpkgs`.


## Implementation

```nix
#*/# end of MarkDown, beginning of Nix test:
dirname: inputs: pkgs: let
    inherit (inputs.self) lib;
    inherit (lib.th.testing pkgs) toplevel override unpinInputs resize dropRefs time disk-usage frame nix-store-send run-in-vm;

    keep-nix = { pkgs, config, ... }: { # got to keep Nix (and it's DBs) for this
        nix.enable = lib.mkForce true;
        systemd.services.nix-daemon.path = lib.mkForce ([ config.nix.package.out pkgs.util-linux ] ++ lib.optionals config.nix.distributedBuilds [ pkgs.gzip ]); # remove »config.programs.ssh.package«
        fileSystems."/system" = { options = lib.mkForce [ "noatime" ]; }; # remove »ro«
        fileSystems."/nix/var" = { options = [ "bind" "rw" "private" ]; device = "/system/nix/var"; };
        environment.systemPackages = [ pkgs.nix ];
    };

    new = override (resize "4G" (unpinInputs inputs.self.nixosConfigurations."new:x64-minimal")) {
        wip.services.dropbear.rootKeys = lib.readFile "${inputs.self}/utils/res/ssh_testkey_1.pub";
        environment.etc.version.text = "new";
        imports = [ keep-nix ];
    };
    old = override (resize "4G" (unpinInputs inputs.self.nixosConfigurations."old:x64-minimal")) {
        environment.etc.version.text = "old";
        imports = [ keep-nix ];
    };
    clb = override old ({ config, ... }: {
        nixpkgs.overlays = lib.mkIf (!config.system.build?isVmExec) [ (final: prev: {
            glibc = prev.glibc.overrideAttrs (old: { trivialChange = 42 ; });
            libuv = prev.libuv.overrideAttrs (old: { doCheck = false; });
        }) ];
        system.nixos.tags = [ "glibc" ];
        environment.etc.version.text = lib.mkForce "clb";
    });

    systems = { inherit new old clb; };

    nix-copy-closure = before: after: ''
        ${frame ''echo "Update (${before} -> ${after})"''}
        echo "Update stream stats (${before} -> ${after})"
        cat ${nix-store-send systems.${before} systems.${after} ""}/stats
        echo "stream size: $(du --apparent-size --block-size=1 ${nix-store-send systems.${before} systems.${after} ""}/stream | cut -f1)"
        echo "stream path: ${nix-store-send systems.${before} systems.${after} ""}"
        ${run-in-vm systems.${before} { } (let
        in [
            { pre = ''
                $ssh -- '${disk-usage}'
                ( PATH=$PATH:${pkgs.openssh}/bin ; ${time "bash -c 'NIX_SSHOPTS=$sshOpts ${pkgs.nix}/bin/nix-copy-closure --to root@127.0.0.1 ${toplevel systems.${after}} 2>&1 | head -n1'"} )
            ''; test = ''
                echo "This is version $(cat /etc/version)" ; if [[ $(cat /etc/version) != ${before} ]] ; then echo "dang ..." ; false ; fi
                ${disk-usage}
                echo "total traffic of »nix-copy-closure«:" $( ${pkgs.inetutils}/bin/ifconfig --interface=ens3 | ${pkgs.gnugrep}/bin/grep -Pe 'RX bytes:' )
                ( set -x ; ${dropRefs (toplevel systems.${after})}/install-bootloader 1 )
                #( ${time "nix-store --gc"} ) 2>&1 | tail -n2 # delete the new version, to see how long GC takes (only the old version is registered with Nix and thus won't be GCed)
            ''; }
            { test = ''
                echo "This is version $(cat /etc/version)" ; if [[ $(cat /etc/version) != ${after} ]] ; then echo "dang ..." ; false ; fi
            ''; }
            { pre = ''
                ( set -x ; cat ${dropRefs (nix-store-send systems.${before} systems.${after} "")}/stream ) | $ssh -- '${time "nix-store-recv --only-read-input --status"}'
            ''; test = ''
                echo "total traffic of »nix-store-recv«:" $( ${pkgs.inetutils}/bin/ifconfig --interface=ens3 | ${pkgs.gnugrep}/bin/grep -Pe 'RX bytes:' )
            ''; }
        ])}
    '';

in ''
echo "old system: ${toplevel old}"
echo "new system: ${toplevel new}"
echo "clb system: ${toplevel clb}"
echo
${nix-copy-closure "old" "new"}
echo
${nix-copy-closure "old" "clb"}

''
#${frame "echo nix copy"}
#${run-in-vm old { } (let
#in [
#    { pre = ''
#        ( PATH=$PATH:${pkgs.openssh}/bin ; set -x ; NIX_SSHOPTS=$sshOpts ${pkgs.nix}/bin/nix --extra-experimental-features nix-command copy --no-check-sigs --to ssh://127.0.0.1 ${toplevel new} )
#    ''; test = ''
#        echo "This is version $(cat /etc/version)" ; if [[ $(cat /etc/version) != old ]] ; then echo "dang ..." ; false ; fi
#        ${disk-usage}
#        ( set -x ; ${dropRefs (toplevel new)}/install-bootloader 1 )
#    ''; }
#    { test = ''
#        echo "This is version $(cat /etc/version)" ; if [[ $(cat /etc/version) != new ]] ; then echo "dang ..." ; false ; fi
#    ''; }
#])}
