
# x86_64/aarch64 EFI Target

Test configuration of (emulated) x64/arm target devices.


## Installation

To prepare the virtual machine disk, with `nix` installed (with sandbox support), run:
```bash
 nix run '.#x64' -- install-system /tmp/x64.img
```
When not running as toot (or when additionally supplying the `--vm` flag), the installation is performed in a qemu VM.

Then as user that can use KVM (or very slowly without KVM) to run the VM(s):
```bash
 nix run '.#x64' -- run-qemu --efi /tmp/x64.img
```

Replace the `x64` with `arm` or any of the names of variants listed in [`wip.preface.instances`](./default.nix) to install/start those hosts instead.
