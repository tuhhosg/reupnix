/*

# Installation Size

Measurement of the size of a minimal, bare-bones system.


## Implementation

```nix
#*/# end of MarkDown, beginning of Nix test:
dirname: inputs: pkgs: let
    inherit (inputs.self) lib;
    inherit (lib.th.testing pkgs) toplevel override unpinInputs measure-installation collect-deps merge-deps;
    update-glibc = system: override system ({ config, ... }: {
        nixpkgs.overlays = lib.mkIf (!config.system.build?isVmExec) [ (final: prev: {
            glibc = prev.glibc.overrideAttrs (old: { trivialChange = 42 ; });
        }) ];
    });

    target = if pkgs.system == "aarch64-linux" then "rpi" else "x64";
    base-new = unpinInputs inputs.self.nixosConfigurations."new:${target}-baseline";
    base-old = unpinInputs inputs.self.nixosConfigurations."old:${target}-baseline";
    base-clb = update-glibc base-new;
    mini-new = unpinInputs inputs.self.nixosConfigurations."new:${target}-minimal";
    mini-old = unpinInputs inputs.self.nixosConfigurations."old:${target}-minimal";
    mini-clb = update-glibc mini-new;
    #x64 = unpinInputs inputs.self.nixosConfigurations."new:x64-minimal";
    #rpi = unpinInputs inputs.self.nixosConfigurations."new:rpi-minimal";

in ''
${lib.concatStringsSep "\n" (lib.mapAttrsToList (size: { new, old, clb, }: ''
echo
echo "Installation measurements (${target}-${size}):"
${measure-installation new ''
    echo "du --apparent-size /nix/store: $( du --apparent-size --block-size=1 --summarize $mnt/system/nix/store | cut -f1 )"
    rm -rf $mnt/system/nix/store/.links
    storeSize=$(                            du --apparent-size --block-size=1 --summarize $mnt/system/nix/store | cut -f1 )
    echo "(without /nix/store/.links):   $storeSize"
    ${pkgs.util-linux}/bin/mount --fstab ${new.config.system.build.toplevel}/etc/fstab --target-prefix $mnt/ /boot
    df --block-size=1 $mnt/boot $mnt/system
    bootSize=$( df --block-size=1 --output=used -- $mnt/boot | tail -n+2 )
    systemSize=$( df --block-size=1 --output=used -- $mnt/system | tail -n+2 )
    mkdir -p $out/dref-ext
    echo "\drefset{/${target}/${size}/store/used}{$storeSize}" >>$out/dref-ext/install-${target}-${size}.tex
    echo "\drefset{/${target}/${size}/boot/used}{$bootSize}" >>$out/dref-ext/install-${target}-${size}.tex
    echo "\drefset{/${target}/${size}/system/used}{$systemSize}" >>$out/dref-ext/install-${target}-${size}.tex

    mkdir -p $out/systems
    ${pkgs.python3.withPackages (pip3: (builtins.attrValues rec { inherit (pip3) python-magic pandas; }))}/bin/python3 ${dirname}/../lib/system-listing.py ${target}/${size} $mnt/system/nix/store $out/systems/${target}_${size}.csv
''}
echo
echo "normal installation: ${collect-deps (toplevel new)}"
echo "number of files:    $( find ${collect-deps (toplevel new)} -type f | wc -l )"
echo "number of dirs:     $( find ${collect-deps (toplevel new)} -type d | wc -l )"
echo "number of symlinks: $( find ${collect-deps (toplevel new)} -type l | wc -l )"
echo "overall size:       $( du --apparent-size --block-size=1 --summarize ${collect-deps (toplevel new)} | cut -f1 )"
echo "thereof symlinks:   $(( $( du --apparent-size --block-size=1 --summarize ${collect-deps (toplevel new)} | cut -f1 ) - $( du --apparent-size --block-size=1 --summarize ${(collect-deps (toplevel new)).clean} | cut -f1 ) ))"
echo
echo "merged components: ${merge-deps (toplevel new)}"
echo "number of files:    $( find ${merge-deps (toplevel new)} -type f | wc -l )"
echo "number of dirs:     $( find ${merge-deps (toplevel new)} -type d | wc -l )"
echo
'') { baseline = { new = base-new; old = base-old; clb = base-clb; }; minimal = { new = mini-new; old = mini-old; clb = mini-clb; }; })}
''
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
