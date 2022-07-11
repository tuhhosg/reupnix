
# x86_64 EFI Target

Test configuration of (emulated) x64 target devices.


## Installation

To prepare the virtual machine disk, as `root` and with `nix` installed, run:
```bash
 nix run '.#x64' -- install-system /tmp/x64.img
```
Then as user that can use KVM to run the VM(s):
```bash
 nix run '.#x64' -- run-qemu /tmp/x64.img
```
Alternative to running directly as `root` (esp. if `nix` is not installed for root), the above commands can also be run with `sudo` as additional argument before the `--`.
