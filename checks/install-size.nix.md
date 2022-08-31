/*

# Installation Size

Measurement of the size of a minimal, bare-bones system.


## Implementation

```nix
#*/# end of MarkDown, beginning of Nix test:
dirname: inputs: pkgs: let
    inherit (inputs.self) lib;
    inherit (lib.th.testing pkgs) toplevel override unpinInputs measure-installation collect-deps merge-deps;

    uut = unpinInputs inputs.self.nixosConfigurations.x64-minimal;
    base = unpinInputs inputs.self.nixosConfigurations.x64-baseline;

in ''
echo "Installation measurements (x64-baseline):"
${measure-installation base ''
    echo "du --apparent-size /nix/store: $( du --apparent-size --block-size=1 --summarize $mnt/system/nix/store | cut -f1 )"
    rm -rf $mnt/system/nix/store/.links
    echo "(without /nix/store/.links):   $( du --apparent-size --block-size=1 --summarize $mnt/system/nix/store | cut -f1 )"
    ${pkgs.util-linux}/bin/mount --fstab ${base.config.system.build.toplevel}/etc/fstab --target-prefix $mnt/ /boot
    df --block-size=1 $mnt/system $mnt/boot
''}
echo
echo "Installation measurements (x64-minimal):"
${measure-installation uut ''
    echo "du --apparent-size /nix/store: $( du --apparent-size --block-size=1 --summarize $mnt/system/nix/store | cut -f1 )"
    rm -rf $mnt/system/nix/store/.links
    echo "(without /nix/store/.links):   $( du --apparent-size --block-size=1 --summarize $mnt/system/nix/store | cut -f1 )"
    ${pkgs.util-linux}/bin/mount --fstab ${uut.config.system.build.toplevel}/etc/fstab --target-prefix $mnt/ /boot
    df --block-size=1 $mnt/system $mnt/boot
''}
echo
echo "normal installation: ${collect-deps (toplevel uut)}"
echo "number of files:    $( find ${collect-deps (toplevel uut)} -type f | wc -l )"
echo "number of dirs:     $( find ${collect-deps (toplevel uut)} -type d | wc -l )"
echo "number of symlinks: $( find ${collect-deps (toplevel uut)} -type l | wc -l )"
echo "overall size:       $( du --apparent-size --block-size=1 --summarize ${collect-deps (toplevel uut)} | cut -f1 )"
echo "thereof symlinks:   $(( $( du --apparent-size --block-size=1 --summarize ${collect-deps (toplevel uut)} | cut -f1 ) - $( du --apparent-size --block-size=1 --summarize ${(collect-deps (toplevel uut)).clean} | cut -f1 ) ))"
echo
echo "merged components: ${merge-deps (toplevel uut)}"
echo "number of files:    $( find ${merge-deps (toplevel uut)} -type f | wc -l )"
echo "number of dirs:     $( find ${merge-deps (toplevel uut)} -type d | wc -l )"

''
