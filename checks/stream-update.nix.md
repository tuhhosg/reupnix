/*

# Update via `nix-store-send`

An example of the send stream, substantially updating `nixpkgs`.


## Notes

* The closure installed ("installing system") is different from the "old system" (and bigger) because the former also includes the test scripts, and some dependencies they pull in
    * "installing system" does completely contain "old system", though, so this should not matter.
    * Actually, it's odd that applying the stream decreases the disk utilization. Anything in "installing system" and not in "old system" should remain.


## Implementation

```nix
#*/# end of MarkDown, beginning of Nix test:
dirname: inputs: pkgs: let
    lib = inputs.self.lib.__internal__;
    inherit (lib.th.testing pkgs) toplevel override unpinInputs resize dropRefs time disk-usage nix-store-send run-in-vm;

    new = override (resize "512M" (unpinInputs inputs.self.nixosConfigurations."new:x64-minimal")) {
        wip.services.dropbear.rootKeys = lib.readFile "${inputs.self}/utils/res/ssh_testkey_1.pub";
        environment.etc.version.text = "new";
    };
    old = override (resize "512M" (unpinInputs inputs.self.nixosConfigurations."old:x64-minimal")) {
        environment.etc.version.text = "old";
    };

    # * read-input:     Receive instructions and new files
    # * restore-links:  Restore hardlinks to existing files
    # * install:        Install new components to the store
    # * save-links:     Save hardlinks to new files
    # * delete:         Remove old components from the store
    # * prune-links:    Prune hardlinks to files no longer needed
    # * cleanup:        Remove instructions and temporary hardlinks
    update-cmds = [
        { pre = ''
            $ssh -- '${disk-usage}'
            ( set -x ; cat ${dropRefs (nix-store-send old new "")}/stream ) | $ssh -- '${time "nix-store-recv --only-read-input --status"}'

        ''; test = ''
            echo "total traffic:" $( ${pkgs.inetutils}/bin/ifconfig --interface=ens3 | ${pkgs.gnugrep}/bin/grep -Pe 'RX bytes:' )

            echo "This is version $(cat /etc/version)" ; if [[ $(cat /etc/version) != old ]] ; then echo "dang ..." ; false ; fi
            ${disk-usage}

            ${time "nix-store-recv --only-restore-links"}
            ${time "nix-store-recv --only-install"}
            ${time "nix-store-recv --only-save-links"}

            ( set -x ; ${dropRefs (toplevel new)}/install-bootloader 1 )
        ''; }
        { test = ''
            echo "This is version $(cat /etc/version)" ; if [[ $(cat /etc/version) != new ]] ; then echo "dang ..." ; false ; fi
            ${disk-usage}

            ${time "nix-store-recv --only-delete"}
            ${time "nix-store-recv --only-prune-links"}
            ${time "nix-store-recv --only-cleanup"}

            ${disk-usage}
        ''; }
        { pre = ''
            $ssh -- '${disk-usage}'
            ( set -x ; cat ${dropRefs (nix-store-send old new "")}/stream ) | $ssh -- '${time "nix-store-recv --status"}'
            $ssh -- '${disk-usage}'

        ''; test = ''
            echo "total traffic:" $( ${pkgs.inetutils}/bin/ifconfig --interface=ens3 | ${pkgs.gnugrep}/bin/grep -Pe 'RX bytes:' )
            echo "This is version $(cat /etc/version)" ; if [[ $(cat /etc/version) != new ]] ; then echo "dang ..." ; false ; fi
        ''; }
    ];

in { script = '''
echo "old system: ${toplevel old}"
echo "new system: ${toplevel new}"
echo "Update stream stats (old -> new)"
cat ${nix-store-send old new ""}/stats
echo "stream size: $(du --apparent-size --block-size=1 ${nix-store-send old new ""}/stream | cut -f1)"
echo "stream path: ${nix-store-send old new ""}"
echo
${run-in-vm old { } update-cmds}
echo
${run-in-vm old { override = {
    installer.commands.postInstall = ''true || rm -rf $mnt/system/nix/store/.links'';
}; } update-cmds}
''; }
