/*

# `nix-store-send` Rsync Transfer

Testing how much could be gained by transferring the send stream differentially via rsync.

Notes:
* The client could in principle reconstruct the (null -> old) stream, though one would not want to do that explicitly.
* The files in both streams are sorted alphabetically by their hashes, meaning they are essentially shuffled, since only changed files are included in the (old -> new) stream.

Rsync works by splitting the old version of the target file into fixed-size chunks, and building a cheap hash sum for each. On the senders side, it then uses a rolling algorithm to compute the same hash sum at every byte offset in the new file. If matches are found with the old chunks, they are verified with a stronger hash sum, and if they match, the chunk can be reused from the old file, instead of transferring it.
The advantage of checking every position in the new file is that chunks will be found even if they moved.

Other algorithms (like `casync`) divide files into chunks wherever they find certain byte sequences (essentially by computing efficient rolling hash sums over short sequences of bytes at every byte offset, and then chunking when the hash has a certain form). They then hash the chunks with a stronger algorithm and only transfers those chunks that don't exist on the target yet.
This also ensures that chunks that move in their entirety, e.g. because a file moved within the stream, will be recognized just the same.

The problem with shuffling the files, however, is that any chunk that spanned across the divide of two files will not occur anymore, even if neither file changed in the regions within the chunk, as it is extremely unlikely that the same two files will again occur as neighbors in that order.
How much that matters depends on the number of files and the average size of the chunks, since every file invalidates one potentially unchanged chunk.


## Implementation

```nix
#*/# end of MarkDown, beginning of Nix test:
dirname: inputs: pkgs: let
    inherit (inputs.self) lib; test = lib.th.testing pkgs;

    remove-containers = system: test.override system { # »override« (for some reason) does not affect containers, and targeting it explicitly also doesn't work ...
        specialisation.test1.configuration.th.target.containers.containers = lib.mkForce { };
    };

    old = remove-containers (test.unpinInputs inputs.self.nixosConfigurations."old:x64-minimal");
    new = remove-containers (test.unpinInputs inputs.self.nixosConfigurations."new:x64-minimal");
    clb = test.override new ({ config, ... }: { nixpkgs.overlays = lib.mkIf (!config.system.build?isVmExec) [ (final: prev: {
        glibc = prev.glibc.overrideAttrs (old: { trivialChange = 42 ; });
        libuv = prev.libuv.overrideAttrs (old: { doCheck = false; });
    }) ]; system.nixos.tags = [ "glibc" ]; });

in ''
# Using »--dry-run« invalidates the measurement, so the old file needs to be copied.

( ${test.frame "echo 'real update'"} ) 1>&2
echo -n "\addplot coordinates {" > plotUp
echo -n "\addplot coordinates {" > plotDt
echo -n "\addplot coordinates {" > plotDw

for size in 8 16 32 64 128 256 512 1k 2k 4k 8k 16k 32k 64k 128k ; do
    echo $'\n'"Differential rsync transfer of update stream onto initial image (with names, block size $size)" 1>&2
    rm -rf ./prev ; cp ${test.nix-store-send null old ""}/stream ./prev
    data=$( ${pkgs.rsync}/bin/rsync --no-whole-file --stats --block-size=$size ${test.nix-store-send old new ""}/stream ./prev )
    <<<"$data" grep -Pe 'Total|data' 1>&2

    data=$( <<<"$data" sed s/,//g )
    echo -n " ($size,$( <<<"$data" grep -oPe 'Total bytes sent: \K\d+' ))" >>plotUp
    echo -n " ($size,$( <<<"$data" grep -oPe 'Literal data: \K\d+' ))" >>plotDt
    echo -n " ($size,$( <<<"$data" grep -oPe 'Total bytes received: \K\d+' ))" >>plotDw
done

echo " }; % real up"   >>plotUp
echo " }; % real new"  >>plotDt
echo " }; % real down" >>plotDw
if [[ ,''${args[plot]:-}, == *,1,* ]] ; then cat plot* ; fi

echo $'\n'"Differential rsync transfer of update stream onto initial image (without names, block size 512)" 1>&2
rm -rf ./prev ; cp ${test.nix-store-send null old "--no-names"}/stream ./prev
${pkgs.rsync}/bin/rsync --no-whole-file --stats --block-size=700 ${test.nix-store-send old new "--no-names"}/stream ./prev | grep -Pe 'Total|data' 1>&2

( echo ; echo ) 1>&2
( ${test.frame "echo 'invalidate glibc'"} ) 1>&2
echo -n "\addplot coordinates {" > plotUp
echo -n "\addplot coordinates {" > plotDt
echo -n "\addplot coordinates {" > plotDw

for size in 8 16 32 64 128 256 512 1k 2k 4k 8k 16k 32k 64k 128k ; do
    echo $'\n'"Differential rsync transfer of update stream onto initial image (with names, block size $size)" 1>&2
    rm -rf ./prev ; cp ${test.nix-store-send null new ""}/stream ./prev
    data=$( ${pkgs.rsync}/bin/rsync --no-whole-file --stats --block-size=$size ${test.nix-store-send new clb ""}/stream ./prev )
    <<<"$data" grep -Pe 'Total|data' 1>&2

    data=$( <<<"$data" sed s/,//g )
    echo -n " ($size,$( <<<"$data" grep -oPe 'Total bytes sent: \K\d+' ))" >>plotUp
    echo -n " ($size,$( <<<"$data" grep -oPe 'Literal data: \K\d+' ))" >>plotDt
    echo -n " ($size,$( <<<"$data" grep -oPe 'Total bytes received: \K\d+' ))" >>plotDw
done

echo " }; % glibc up"   >>plotUp
echo " }; % glibc new"  >>plotDt
echo " }; % glibc down" >>plotDw
if [[ ,''${args[plot]:-}, == *,2,* ]] ; then cat plot* ; fi

echo $'\n'"Differential rsync transfer of update stream onto initial image (without names, block size 512)" 1>&2
rm -rf ./prev ; cp ${test.nix-store-send null new "--no-names"}/stream ./prev
${pkgs.rsync}/bin/rsync --no-whole-file --stats --block-size=700 ${test.nix-store-send new clb "--no-names"}/stream ./prev | grep -Pe 'Total|data' 1>&2
''
