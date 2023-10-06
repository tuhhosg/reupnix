/*

# Non-Interactive `nix copy`

`nix copy` copies build outputs from one store to another, but it interactively reads from both stores to build the diff that actually needs copying, and it copies whole store components (as Nix Archives (NAR)).

This implements a copy mechanism that works more akin to a `zfs send`/`zfs receive` pair; that is, there is a first part of the process that runs on the source only, and generates a differential upload stream/archive, which can then be stored or directly forwarded to be applied on the target.

The advantage is that this removes load from the target. With a correct diff, the communication is reduced to an absolute minimum (no interaction, just a single file upload / stream), and nothing needs to be read and not much to be computed on the target.
The current implementation diffs with whole-file granularity, which could be improved.


## Sending

`nix-store-send` needs to be called with a set of desired target (`after`) store root components and a set of store root components that are assumed to be existing `before` on the target (and exist locally).

These are then both expanded to all their dependencies, and any diff in store components is packed into an archive stream, together with unpacking instructions.
`nix-store-send` hashes each file it processes, to optimize the send stream to include files (by content) only once, and only if they are not also referenced from `before` components.
The hashes are the same as the ones `nix-store --optimize` creates in `/nix/store/.links/`.


### Description of Implementation

Naming convention:
* *files* are (the names of) elements in the `/nix/store/.links/` directory (which contains regular files and symbolic links)
* *components* (`*Comps`) are (the names of) elements in the `/nix/store/` directory
    * components are hardlinks to files or directories containing hardlinks to files (recursively)

* assessment: build sets of `afterComps` and `beforeComps` components including dependencies
    * let `\` be the complement operator on sets or keys of a map, `!` extract the keys of a map as a set, and `findFiles` be a function that, for a set of components, finds all files in those components and builds a multi-map `<file-hash,link-path>`
    * `createComps = afterComps \ beforeComps` # components we create
    * `pruneComps = beforeComps \ afterComps` # components we no longer need
    * `keepComps = beforeComps \ pruneComps` # components we keep
    * `linkHM = findFiles(createComps)` # files linked from components that we create (i.e. will create new links to)
    * `keepHM = findFiles(keepComps)` # files linked from components that we keep
    * `oldHM = findFiles(pruneComps)` # files linked from components that we can delete
    * `pruneHL = !oldHM \ !keepHM \ !linkHM` # files we no longer need
    * `uploadHL = !linkHM \ !keepHM \ !oldHM` # files we need but don't have
    * `restoreHL = !linkHM \ uploadHL` # files we need and have (just not in the .links dir)
* sending: `tar` to stdout:
    * `.restore-links` (optional): `${hash}=$(file $hash)\0` for each `hash` in `restoreHL`, where `file` is a function returning an entry from `restoreHL` or `restoreHL` (i.e., for each file we'll need to hardlink, one of the paths where it exists)
    * `.cerate-paths`: serialize `linkHM` as per below instructions
    * `.delete-paths`: serialize `pruneComps` as `\n` separated list of `$(basename $path)`
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

The serialization of the script should be compact and simple/fast to parse (in bash). Possible values are instructions, hashes and file/directory names. Names only occur as last argument, and can not contain `\`, `\0` or the zero byte in general.
Therefore we use `\0` as line terminator and `/` as separator between instructions and arguments.
With one byte/character per text label, this is about as compact as it gets (for variable-length fields), and a simple replace of `\0` by `\n` (and `/` by ` `) makes the file quite readable (for standard file names).

Example (printable version):
```bash
r # start new component
f <hash> - hash-name # link file with <hash> directly as single-file store component
# (still at top level)
d hash-name # create directory for next component
d bin # create subdirectory
f <hash> x prog # link file <hash> (which is executable)
p # go to parent dir
d lib # create subdirectory
d share # create nested subdirectory
f <hash> - lib.o # link files
f <hash> - lib.1.o
r # start new component
d hash-name # ...
[...]
```


## Receiving

`nix-store-recv` accepts a (flat) `tar` stream on `stdin` and unpacks it to a temporary directory on the same file system as the `/nix/store/` (or a path to either of those).

It can work by amending an existing `/nix/store/.links/` list, or it can re-create the required parts of it.
If the links list does not exist already, the `tar`/dir must included the `.restore-links` file; otherwise it should contain the `.prune-links` file.

Note that while a receive is in progress, or if one was aborted and not rolled back, there may be partial store paths, and the dependency closure invariant (that all dependencies of an existing path also exist) may very well be violated. This should be non-critical, since Nix itself won't be accessing the store (and the databases are missing/outdated anyway).


### Description of the Implementation

If `/nix/store/.links/` exists, move all files from the temp dir into it, but do keep a list of all moved files (edit: or just defer the moving).
Otherwise, for each entry in `.restore-links`, hard-link the path after the `=` as the hash before the `=` into the temporary directory, then move the temporary directory to `/nix/store/.links/`.

Execute the `.cerate-paths` script by executing the commands as translated above in the sequence they occur in the script. For any `d` or `f` directly following an `r`, add its `name` argument to a list of added store components.
TODO: Make creation of store components atomic, e.g. : On `r`, rename the previous path to remove the `.tmp.`-prefix; when `d` or `f` directly follow an (implicit) `r`, prefix `name` with `.tmp.`.
Delete `/nix/store/.links/` if it got restored.

To remove everything that was existed `before` but should not `after`, delete all store components listed in `.delete-paths` and, if both exist, all `/nix/store/.links/` files listed in `.prune-links`.

Before deleting the old components, tests on the new set of components can and should be performed. If the tests or the unpacking fail, a rollback can be performed:
If `/nix/store/.links/` got restored and exists, delete it; else, delete all files moved into it, so they exist.
Delete all store components listed in the list of added store components (which, if lost, can be extracted by dry-running `.cerate-paths`).


## Implementation

```nix
#*/# end of MarkDown, beginning of NixPkgs overlay:
dirname: inputs: final: prev: let
    inherit (final) pkgs; lib = inputs.self.lib.__internal__;
    genericArgParse = lib.fun.extractBashFunction (builtins.readFile lib.inst.setup-scripts.utils) "generic-arg-parse";
    genericArgHelp = lib.fun.extractBashFunction (builtins.readFile lib.inst.setup-scripts.utils) "generic-arg-help";
    genericArgVerify = lib.fun.extractBashFunction (builtins.readFile lib.inst.setup-scripts.utils) "generic-arg-verify";
in {

    nix-store-send = pkgs.substituteAll {
        src = ./nix-store-send.sh; dir = "bin"; name = "nix-store-send"; isExecutable = true;
        shell = "${pkgs.bash}/bin/bash";
        nix = "${pkgs.nix}/bin/nix --extra-experimental-features nix-command";
        narHash = "${pkgs.nar-hash}/bin/nar-hash";
        inherit genericArgParse;
    };
    nix-store-recv = pkgs.substituteAll {
        src = ./nix-store-recv.sh; dir = "bin"; name = "nix-store-recv"; isExecutable = true;
        shell = "${pkgs.bash}/bin/bash";
        unshare = "${pkgs.util-linux}/bin/unshare";
        xargs = "${pkgs.findutils}/bin/xargs";
        inherit genericArgParse genericArgHelp genericArgVerify;
    };

    nar-hash = pkgs.runCommandLocal "nar-hash" {
        src = ./nar-hash.cc; nativeBuildInputs = [ pkgs.buildPackages.gcc pkgs.buildPackages.openssl ];
    } ''
        mkdir -p $out/bin/
        g++ -std=c++17 -lcrypto -lssl -O3 $src -o $out/bin/nar-hash
    '';

}
