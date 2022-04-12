
# Some Patches

... for `nixpkgs` or programs therein.

A patch `<name>-*.patch` is generally for the open source software `<name>` which is added/modified by the nixpkgs overlay in `../overlays/<name>.nix.md`.
Patches for `nixpkgs` are applied in `../flake.nix`.

To create/"commit" a patch of the current directory vs its latest commit:
```bash
 git diff >.../overlays/patches/....patch
```

To test a patch against the repo in CWD, or to "check it out" to edit and then "commit" again:
```bash
 git reset --hard HEAD # destructively reset the working tree to the current commit
 patch --dry-run -p1 <.../overlays/patches/....patch # test only
 patch           -p1 <.../overlays/patches/....patch # apply to CWD
```


## License

Patches included in this repository are written by the direct contributors to this repository (unless individually noted otherwise; pre-existing patches should be referenced by URL).

Each individual patch shall be licensed by the most permissive license (up to common domain / CC0) that the software it is for (and derived from) allows.
Usually that would probably be the license of the original software itself, which should be mentioned in the respective overlay and/or the linked source code.
