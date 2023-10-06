/*

# Installation Size

Measurement of the size of a minimal, bare-bones system.


## Implementation

```nix
#*/# end of MarkDown, beginning of Nix test:
dirname: inputs: pkgs: let mkExport = target: let
    lib = inputs.self.lib.__internal__;
    inherit (lib.th.testing pkgs) toplevel override overrideBase unpinInputs measure-installation collect-deps merge-deps;
    cross-compile = localSystem: targetSystem: system: if (localSystem == targetSystem) then system else /* override */ (overrideBase system ({
        nixpkgs = lib.mkForce { localSystem.system = localSystem; crossSystem.system = targetSystem; };
        imports = [ { nixpkgs.overlays = [ (final: prev: { # When cross-compiling (from »nixpkgs-old«), some package pulled in by the default perl env fails to build. This manually applies #182457. Unfortunately, it does not seem to affect the specializations (probably related to the order of module content and argument evaluation), so building still fails. The 2nd import also does not help. This is not a problem for the »minimal« systems, since they don't include perl.
            perl534 = prev.perl534.overrideAttrs (old: {
                passthru = old.passthru // { pkgs = old.passthru.pkgs.override {
                    overrides = (_: with (lib.recurseIntoAttrs prev.perl534.pkgs); {
                        LWP = LWP.overrideAttrs (old: {
                            propagatedBuildInputs = [ FileListing HTMLParser HTTPCookies HTTPNegotiate NetHTTP TryTiny WWWRobotRules ];
                            buildInputs = [ ];
                            checkInputs = [ HTTPDaemon TestFatal TestNeeds TestRequiresInternet ];
                        });
                    });
                }; };
            });
        }) ]; } ({ config, pkgs, ... }: /* lib.mkIf (config.specialisation == { }) */ {
            specialisation.default.configuration.nixpkgs.pkgs = lib.mkForce pkgs;
            specialisation.test1.configuration.nixpkgs.pkgs = lib.mkForce pkgs;
        }) ];
    }));

    targetSystem = { rpi = "aarch64-linux"; x64 = "x86_64-linux"; }.${target};
    baseline = cross-compile pkgs.system targetSystem (unpinInputs inputs.self.nixosConfigurations."new:${target}-baseline");
    minimal  = cross-compile pkgs.system targetSystem (unpinInputs inputs.self.nixosConfigurations."new:${target}-minimal");
    #x64 = unpinInputs inputs.self.nixosConfigurations."new:x64-minimal";
    #rpi = unpinInputs inputs.self.nixosConfigurations."new:rpi-minimal";

in { inherit baseline minimal; script = ''
${lib.concatStringsSep "\n" (lib.mapAttrsToList (size: system: ''
echo
echo "Installation measurements (${target}-${size}):"
${measure-installation system ''
    echo "du --apparent-size /nix/store: $( du --apparent-size --block-size=1 --summarize $mnt/system/nix/store | cut -f1 )"
    rm -rf $mnt/system/nix/store/.links
    storeSize=$(                            du --apparent-size --block-size=1 --summarize $mnt/system/nix/store | cut -f1 )
    echo "(without /nix/store/.links):   $storeSize"
    ${pkgs.util-linux}/bin/mount --fstab ${system.config.system.build.toplevel}/etc/fstab --target-prefix $mnt/ /boot
    df --block-size=1 $mnt/boot $mnt/system
    bootSize=$( df --block-size=1 --output=used -- $mnt/boot | tail -n+2 )
    systemSize=$( df --block-size=1 --output=used -- $mnt/system | tail -n+2 )
    mkdir -p $out/dref-ext
    echo "\drefset{/${target}/${size}/store/used}{$storeSize}" >>$out/dref-ext/install-${target}-${size}.tex
    echo "\drefset{/${target}/${size}/boot/used}{$bootSize}" >>$out/dref-ext/install-${target}-${size}.tex
    echo "\drefset{/${target}/${size}/system/used}{$systemSize}" >>$out/dref-ext/install-${target}-${size}.tex

    mkdir -p $out/systems
    ${pkgs.python3.withPackages (pip3: (builtins.attrValues rec { inherit (pip3) python-magic pandas; }))}/bin/python3 ${dirname}/../lib/data/system-listing.py ${target}/${size} $mnt/system/nix/store $out/systems/${target}_${size}.csv || { echo python script failed with $? ; false ; }
''}
echo
echo "normal installation: ${collect-deps (toplevel system)}"
echo "number of files:    $( find ${collect-deps (toplevel system)} -type f | wc -l )"
echo "number of dirs:     $( find ${collect-deps (toplevel system)} -type d | wc -l )"
echo "number of symlinks: $( find ${collect-deps (toplevel system)} -type l | wc -l )"
echo "overall size:       $( du --apparent-size --block-size=1 --summarize ${collect-deps (toplevel system)} | cut -f1 )"
echo "thereof symlinks:   $(( $( du --apparent-size --block-size=1 --summarize ${collect-deps (toplevel system)} | cut -f1 ) - $( du --apparent-size --block-size=1 --summarize ${(collect-deps (toplevel system)).clean} | cut -f1 ) ))"
echo
echo "merged components: ${merge-deps (toplevel system)}"
echo "number of files:    $( find ${merge-deps (toplevel system)} -type f | wc -l )"
echo "number of dirs:     $( find ${merge-deps (toplevel system)} -type d | wc -l )"
echo
'') ({ inherit minimal; } // (
    if pkgs.system == targetSystem then { inherit baseline; } else { } # Since cross-compiling of the baseline system fails (see above), only evaluate it when doing native compilation.
)))}
''; }; in {
    scripts = { x64 = (mkExport "x64").script; rpi = (mkExport "rpi").script; };
    systems = { x64 = { inherit (mkExport "x64") baseline minimal; }; rpi = { inherit (mkExport "rpi") baseline minimal ; }; };
}
/*
# (not sure that these work:)
echo "Transfer list (old -> new): ${pkgs.runCommandLocal "transfer-list-old-new-${target}-${size}" { requiredSystemFeatures = [ "recursive-nix" ]; } ''
    before=$( ${pkgs.nix}/bin/nix --extra-experimental-features nix-command --offline path-info -r ${toplevel old} )
    after=$(  ${pkgs.nix}/bin/nix --extra-experimental-features nix-command --offline path-info -r ${toplevel new} )
    <<< "$after"$'\n'"before"$'\n'"before" LC_ALL=C sort | uniq -u >$out
''}"
echo "Transfer list (clb -> new): ${pkgs.runCommandLocal "transfer-list-clb-new-${target}-${size}" { requiredSystemFeatures = [ "recursive-nix" ]; } ''
    before=$( ${pkgs.nix}/bin/nix --extra-experimental-features nix-command --offline path-info -r ${toplevel clb} )
    after=$(  ${pkgs.nix}/bin/nix --extra-experimental-features nix-command --offline path-info -r ${toplevel new} )
    <<< "$after"$'\n'"before"$'\n'"before" LC_ALL=C sort | uniq -u >$out
''}"
*/
