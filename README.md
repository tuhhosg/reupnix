
# reUpNix: Reconfigurable and Updateable Embedded Systems

This repository contains the practical contributions of (my master thesis and) the [paper named above](https://doi.org/10.1145/3589610.3596273).
The abstract:

> Managing the life cycle of an embedded Linux stack is difficult, as we have to integrate in-house and third-party services, prepare firmware images, and update the devices in the field.
> Further, if device deployment is expensive (e.g. in space), our stack should support multi-mission setups to make the best use of our investment.
>
> With reUpNix, we propose a methodology based on NixOS that provides reproducible, updateable, and reconfigurable embedded Linux stacks.
> For this, we identify the shortcomings of NixOS for use on embedded devices, reduce its basic installation size by up to 86 percent, and make system updates failure atomic and significantly smaller.
> We also allow integration of third-party OCI images, which, due to fine-grained file deduplication, require up to 27 percent less on-disk space.

The differential update transfer mechanism `nix store sent` is implemented as part of Nix, and is included here as one big [patch](./patches/nix-store-send.patch) ([`nix-store-send`](./overlays/nix-store-send.nix.md) implements a previous version).

[`modules/hermetic-bootloader.nix.md`](./modules/hermetic-bootloader.nix.md) implements the bootloader configuration, and [`modules/minify.nix.md`](./modules/minify.nix.md) realizes the reduction in installation size.

Container integration is implemented in [`modules/target/containers.nix.md`](./modules/target/containers.nix.md), and the configuration model (Machine Config / System Profile) by the layout of the individual [hosts](./hosts/), [`lib/misc.nix#importMachineConfig`](./lib/misc.nix), and [`modules/target/specs.nix.md`](./modules/target/specs.nix.md).

The description for the LCTES 2023 Artifact Submission can be found in [`utils/lctes23-artifact`](./utils/lctes23-artifact).


## Repo Layout

This is a nix flake repository, so [`./flake.nix`](./flake.nix) is the entry point and export mechanism for almost everything.

[`./lib/`](./lib/) adds some additional library functions as `.th` to the default `nixpkgs.lib`.
These get passed to all other files as `inputs.self.lib.th`.

[`./hosts/`](./hosts/) contains the entry point NixOS config modules for each host(-type).
The `default.nix` specifies the names of multiple `instances` of the host type. The ones with `-minimal` suffix have a standard set of [system minifications](./modules/minify.nix.md) applied, the `-baseline` ones are without minification, and the ones without suffix have some additional debugging bloat enabled.
The `checks` (see below) may further modify the host definitions, but those modifications are not directly exposed as flake outputs.

[`./modules/`](./modules/) contains NixOS configuration modules. Added options' names start with `th.` (unless they are meant as fixes to the existing options set).
[`./modules/default.nix`](./modules/default.nix) exports an attr set of the modules defined in the individual files, which is also what is exported as `flake#outputs.nixosModules` and merged as `flake#outputs.nixosModules.default`.

[`./overlays/`](./overlays/) contains nixpkgs overlays. Some modify packages from `nixpkgs`, others add packages not in there (yet).
[`./overlays/default.nix`](./overlays/default.nix) exports an attr set of the overlays defined in the individual files, which is also what is exported as `flake#outputs.overlays` and merged as `flake#outputs.overlays.default`. Additionally, the added or modified packages are exported as `flake#outputs.packages.<arch>.*`.

[`./utils/`](./utils/) contains the installation and maintenance scripts/functions. These are wrapped by the flake to have access to variables describing a specific host, and thus (with few exceptions) shouldn't be called directly.
See `apps` and `devShells` exported by the flake, plus the [installation](#host-installation--initial-setup) section below.

[`./checks/`](./checks/) contains tests and evaluations. These are built as part of `nix flake check` and can individually be built and executed by running `nix run .#check:<name> -- <args>`.
Some checks produce output files in [`./out/`](./out/). These contain the data for publications and can be copied to the `data/` dir of the papers.


## Host Installation / Initial Setup

The installation of the configured hosts is completely scripted and should work on any Linux with KVM enabled (or root access), and nix installed for the current user (or root).
See [WibLib's `install-system`](https://github.com/NiklasGollenstede/nix-wiplib/blob/master/lib/setup-scripts/README.md#install-system-documentation) for more details.


## Concepts

### `.xx.md` files

Often, the concept expressed by a source code file is at least as important as the concrete implementation of it.
`nix` unfortunately isn't super readable and also does not have documentation tooling support nearly on par with languages like TypeScript.

Embedding the source code "file" within a MarkDown file emphasizes the importance of textual expressions of the motivation and context of each piece of source code, and should thus incentivize writing sufficient documentation

Technically, Nix (and most other code files) don't need to have any specific file extension. By embedding the MarkDown header in a block comment, the file can still be a valid source code file, while the MarDown header ending in a typed code block ensures proper syntax highlighting of the source code in editors or online repos.


## Notepad

### Nix store deduplication

To measure the effectiveness of deduplication on a `/nix/store/`, run:
```bash
 is=0 ; would=0 ; while read perm links user group size rest ; do is=$(( is + size )) ; would=$(( would + (links - 1) * size )) ; done < <( \ls -Al /nix/store/.links | tail -n +2 ) ; echo "Actual size: $is ; without dedup: $would ; gain: $( bc <<< "scale=2 ; $would/$is" )"
```


## Authors / License

All files in this repository ([`reupnix`](https://github.com/tuhhosg/reupnix)) (except LICENSE) are authored/created by the authors of this repository, and are copyright 2023 [Christian Dietrich](https://github.com/stettberger) (`lib/data/*`) and copyright 2022 - 2023 [Niklas Gollenstede](https://github.com/NiklasGollenstede) (the rest).

See [`patches/README.md#license`](./patches/README.md#license) for the licensing of the included [patches](./patches/).
All other parts of this software may be used under the terms of the MIT license, as detailed in [`./LICENSE`](./LICENSE).

This license applies to the files in this repository only.
Any external packages are built from sources that have their own licenses, which should be the ones indicated in the package's metadata.
