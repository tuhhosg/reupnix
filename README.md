
# Lightweight & Reconfigurable Container OS

This is the (very much still work in progress) repository for my master thesis implementation.
From the proposed abstract:

> We [aim to develop] a statically configured container runtime that:
> * reduces runtime overhead, by doing analytical and setup tasks ahead of time and outside the execution environment
> * allows switching between configurations, while minimizing deployment overhead (storage/transmission)
> * requires the containers to declare their real-time requirements, such that they can be statically analyzed and monitored during execution
> * provides containers direct access to dedicated hardware
> * statically configures low-overhead/jitter communication between containers

So far, this uses NixOS to achieve the first two points -- more to follow.


## Design (so far)

A brief description of what we currently expect the base OS deployment to look like:

* Multiple sets of container configurations are provided as input.
* A container configuration is a set of containers, plus a declaration of how to link them to each other, available hardware, and the outside world.
* A container is a file system tree (linux installation minus kernel), plus again some declaration how to start/run it.
* All containers are packed as nix build outputs in the nix store (and are thereby automatically content-deduplicated on a per-file basis).
* A fallback NixOS configuration plus one sub-configuration per container configurations is built.
* The set of NixOS configs is copied to a deployment test system; a snapshot is taken.
* The configuration is tested on the test system.
* If there is a previous snapshot, then the diff between the snapshots is uploaded to the target device and applied there, otherwise the target device is deployed as a clone of the test system.
* The target system gets rebooted into one of the container configs; if that fails, it boots into the fallback config.

![](./docs/relations.drawio.svg)


## Repo Layout

This is a nix flake repository, so [`./flake.nix`](./flake.nix) is the entry point and export mechanism for almost everything.

[`./lib/`](./lib/) adds some additional library functions as `.my` to the default `nixpkgs.lib`. These get passed to all other files as `inputs.self.lib.my`.

[`./hosts/`](./hosts/) contains the main NixOS config modules for each host. Generally, there is one file for each host, but the [flake](./flake.nix) can be instructed to reuse the config for multiple hosts (in which case the module should probably interpret the `name` argument passed to it).
Any `preface.*` options have to be set in the first sub-module in these files (`## Hardware` section).

[`./modules/`](./modules/) contains NixOS configuration modules. Added options' names start with `th.` (unless they are meant as fixes to the existing options set).
The modules are inactive by default, and are designed to be mostly independent from each other and the other things in this repo. Some do have dependencies on added or modified packages, other modules in the same directory, or just aren't very useful outside the overall system setup.
[`./modules/default.nix`](./modules/default.nix) exports an attr set of the modules defined in the individual files, which is also what is exported as `flake#outputs.nixosModules` and merged as `flake#outputs.nixosModule`.

[`./overlays/`](./overlays/) contains nixpkgs overlays. Some modify packages from `nixpkgs`, others add packages not in there (yet).
[`./overlays/default.nix`](./overlays/default.nix) exports an attr set of the overlays defined in the individual files, which is also what is exported as `flake#outputs.overlays` and merged as `flake#outputs.overlay`. Additionally, the added or modified packages are exported as `flake#outputs.packages.<arch>.*`.

[`./utils/`](./utils/) contains the installation and maintenance scripts/functions. These are wrapped by the flake to have access to variables describing a specific host, and thus (with few exceptions) shouldn't be called directly.
See `apps` and `devShells` exported by the flake, plus the [installation](#installation--initial-setup) section below.


## Installation / Initial Setup

The installation is completely scripted and should work on any Linux with root access, and nix installed for either root or the current user.
See [`./utils/install.sh.md`](./utils/install.sh.md)) for more details.


## Concepts

### `.xx.md` files

Often, the concept expressed by a source code file is at least as important as the concrete implementation of it.
`nix` unfortunately isn't super readable and also does not have documentation tooling support nearly on par with languages like TypeScript.

Embedding the source code "file" within a MarkDown file emphasizes the importance of textual expressions of the motivation and context of each piece of source code, and should thus incentivize writing sufficient documentation

Technically, Nix (and most other code files) don't need to have any specific file extension. By embedding the MarkDown header in a block comment, the file can still be a valid source code file, while the MarDown header ending in a typed code block ensures proper syntax highlighting of the source code in editors or online repos.


## Notepad

### `nix repl`

```nix
pkgs = import <nixpkgs> { }
:lf . # load CWD's flake's outputs as variables
pkgs = nixosConfigurations.target.pkgs
lib = lib { inherit pkgs; inherit (pkgs) lib; }
```


### TODOs



### Observations

* With `autoOptimiseStore`, nix deduplicates the files across all derivations in the store based on their content's hash (`nix-hash --type sha256 --base32 $file`).
	* All the hardlinks are stored in a (consequently quite big) directory (`/nix/store/.links`). Is that efficient? What are the lookup times in a dir with several 100k files?
	* It goes so far as to even deduplicate symlinks. Is this worth it for symlinks? Whats the size of a symlink vs a hardlink?
	* I assume derivations are deduped when being copied into the store?
```bash
 is=0 ; would=0 ; while read perm links user group size rest ; do is=$(( is + size )) ; would=$(( would + (links - 1) * size )) ; done <<<"$(ls -Al /nix/store/.links | tail -n +2)" ; echo "Actual size: $is ; without dedup: $would ; gain: $(bc <<< "scale=2 ; $would/$is")"
```
