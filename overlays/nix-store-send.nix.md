/*

# Non-Interactive `nix copy`

`nix copy` copies build outputs from one store to another, but it interactively reads from both stores to build the diff that actually needs copying.

This implements a copy mechanism that works more akin to a `zfs send`/`zfs receive` pair; that is, there is a first part of the process that runs on the source only, and generates a differential upload stream/archive, which can then be stored or directly forwarded to be applied on the target.

The advantage is that this removes load from the target. With a correct diff, the communication is reduced to an absolute minimum (no interaction, just a single file upload / stream), and nothing needs to be read and not much to be computed on the target.


## Sending

`nix-store-send` needs to be called with a set of `wanted` store root artifacts and a set of store root artifacts that are assumed to be `existing` on the target.

These are then both expanded to all their dependencies, and any diff in store artifacts is packed into an archive stream, together with unpacking instructions.

The source store must be automatically/freshly optimized, that is, every file in all referenced artifacts is a hardlink to the content addressed file list in `/nix/store/.links/`.
`nix-store-send` uses this structure to optimize the send stream to include every file (by content) only once, and only if it is not also referenced from `existing`.


### Description of Implementation

Naming convention:
    * "file(s)" are (the names of) elements in the `/nix/store/.links/` directory
    * "artifacts" (`Art`/`Arts`) are (the names of) elements in the `/nix/store/` directory
        * artifacts are hardlinks to files or directories containing hardlinks to files or (recursively)

* assessment: build sets of `wantedArts` and `existingArts` artifacts including dependencies
    * let `\` be the complement operator on sets or keys of a map, `!` extract the keys of a map as set, and `findFiles` be a function that for a set of artifacts finds all files in those artifacts and builds a multi-map `<file-hash,link-path>`
    * `createArts = wantedArts \ existingArts` # artifacts we create
    * `pruneArts = existingArts \ wantedArts` # artifacts we keep
    * `keepArts = existingArts \ pruneArts` # artifacts we no longer need
    * `linkHM = findFiles(createArts)` # files linked from artifacts that we create (i.e. will create new links to)
    * `keepHM = findFiles(keepArts)` # files linked from artifacts that we keep
    * `oldHM = findFiles(pruneArts)` # files linked from artifacts that we can delete
    * `pruneHL = !oldHM \ !keepHM \ !linkHM` # files we no longer need
    * `uploadHL = !linkHM \ !keepHM \ !oldHM` # files we need but don't have
    * `restoreHM = linkHM \ uploadHL` # files we need and have (just not in the .links dir)
* sending: `tar` to stdout:
    * `.restore-links` (optional): `restoreHM<hash, files[]>` mapped to `${hash}=${files[0]}\0` (i.e. for each file we'll need to link some existing path)
    * `.cerate-paths`: serialize `linkHM` as per below instructions
    * `.delete-paths`: serialize `pruneArts` as `\n` separated list of `$(basename $path)`
    * `.prune-links` (optional): serialize `pruneHL` as `\n` separated list
    * new files: from (and relative to) `/nix/store/.links/` all files listed in `uploadHL`


#### `cerate-paths` Linking Script

We build a "script" (sequence of instructions with arguments).
Possible instructions are:
* `r()`: `cd /nix/store/`. This is implicitly the first instruction.
* `d(name)`: `mkdir $name && cd $name`.
* `p()`: `cd ..`. May not exit `/nix/store/`.
* `f(hash,mode,name)`: `ln -T /nix/store/.links/$hash $name && [[ ! mode == *x* ]] || chmod +x $name`.

Flip the `linkHM` (multi) map from `hash => [path]` to `path => hash` and process the keys sorted (with `LC_ALL=C`).
Start with an empty `cwd` stack and no previous path. For each path:
* If the first label of the path is different than the previous path's first label, emit `r()` and clear the stack.
* Split the path at `/`. Call the last element `name` and the list of elements before `dirs`.
    * Form the front, find the first position where `cwd` and `dirs` differ (or either ended).
    * For each element in `cwd` starting at that position, emit `p()` and remove the element.
    * For each element in `dirs` starting at that position, emit `d(dir)` and add that element to `cwd`.
* `stat` `name` in `cwd`, set `mode` to `x` if the file is executable, `-` otherwise.
* Emit `f(hash,mode,name)`.

The serialization of the script should be compact and simple/fast to parse (in bash). Possible values are instructions, hashes and file/directory names. Names only occur as last argument, and can not contain `\`, `\0` or (TODO: is this the case for all possible string encodings?) the zero byte in general.
Therefore we use `\0` as line terminator and `/` as separator between instructions and arguments.
With one byte/character per text label, this is about as compact as it gets, and a simple replace of `\0` by `\n` (and `/` by ` `) makes the file quite readable (for standard file names).
`while IFS=/ read -r -d $'\0' items ...; do ... done`.

Example (printable version)
```
f hash - hash-name
d hash-name
d bin
f hash x prog
p
d lib
d share
f hash - lib.o
f hash - lib.1.o
r
d hash-name
[...]
```


## Receiving

`nix-store-receive` accepts a (flat) `tar` stream on `stdin` and unpacks it to a temporary directory on the same file system as the `/nix/store/` (or a path to either of those).

It can work by amending an existing `/nix/store/.links/` list, or it can re-create the required parts of it.
If the links list does not exist already, the `tar`/dir must included the `.restore-links` file; otherwise it should contain the `.prune-links` file.

Note that while a receive is in progress, or if one was aborted and not rolled back, there may be partial store paths, and the dependency closure invariant (that all dependencies of an existing path also exist) may very well be violated. This should be non-critical, since Nix itself won't be accessing the store (and the databases are missing/outdated anyway).


### Description of Implementation

If `/nix/store/.links/` exists, move all files from the temp dir into it, but do keep a list of all moved files (edit: or just defer the moving).
Otherwise, for each entry in `.restore-links`, hard-link the path after the `=` as the hash before the `=` into the temporary directory, then move the temporary directory to `/nix/store/.links/`.

Execute the `.cerate-paths` script by executing the commands as translated above in the sequence they occur in the script. For any `d` or `f` directly following an `r`, add its `name` argument to a list of added store artifacts.
TODO: Make creation of store artifacts atomic, e.g. : On `r`, rename the previous path to remove the `.tmp.`-prefix; when `d` or `f` directly follow an (implicit) `r`, prefix `name` with `.tmp.`.
Delete `/nix/store/.links/` if it got restored.

To remove everything that was declared as `existing` but not `wanted`, delete all store artifacts listed in `.delete-paths` and, if both exist, all `/nix/store/.links/` files listed in `.prune-links`.

Before deleting the old artifacts, tests on the new set of artifacts can and should be performed. If the tests or the unpacking fail, a rollback can be performed:
If `/nix/store/.links/` got restored and exists, delete it; else, delete all files moved into it, so they exist.
Delete all store artifacts listed in the list of added store artifacts (which, if lost, can be extracted by dry-running `.cerate-paths`).


## Implementation

```nix
#*/# end of MarkDown, beginning of NixPkgs overlay:
dirname: inputs: final: prev: let
    inherit (final) pkgs; inherit (inputs.self) lib;
in {

    nix-store-send = pkgs.substituteAll {
        src = ./nix-store-send.sh; dir = "bin"; name = "nix-store-send"; isExecutable = true;
        shell = "${pkgs.bash}/bin/bash";
        narHash = "${pkgs.nar-hash}/bin/nar-hash";
    };
    nix-store-recv = pkgs.substituteAll {
        src = ./nix-store-recv.sh; dir = "bin"; name = "nix-store-recv"; isExecutable = true;
        shell = "${pkgs.bash}/bin/bash";
        unshare = "${pkgs.util-linux}/bin/unshare";
        xargs = "${pkgs.findutils}/bin/xargs";
        genericArgParse = lib.wip.extractBashFunction (builtins.readFile lib.wip.setup-scripts.utils) "generic-arg-parse";
    };

    # TODO: implement nix-store-receive and test the pair

    nar-hash = pkgs.runCommandLocal "nar-hash" {
        src = ./nar-hash.cc; nativeBuildInputs = [ pkgs.gcc pkgs.openssl ];
    } ''
        mkdir -p $out/bin/
        g++ -std=c++17 -lcrypto -lssl -O3 $src -o $out/bin/nar-hash
    '';

}
