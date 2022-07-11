
# i.MX 8M PlusTarget

Test configuration of an i.MX 8M Plus (EVK) as target device.


## Installation

To prepare the microSD card, adjust the `fs.disks.devices.primary.size` in `./machine.nix` to match the card, and, as `root` and with `nix` installed, run:
```bash
 nix run '.#imx' -- install-system /dev/sdX
```
Then put the card in a PI and boot it.

Alternative to running directly as `root` (esp. if `nix` is not installed for root), the above commands can also be run with `sudo` as additional argument before the `--`.
