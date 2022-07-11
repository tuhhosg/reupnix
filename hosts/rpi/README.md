
# Raspberry Pi Target

Test configuration of a Raspberry PI as target device.


## Installation

To prepare the microSD card, adjust the `fs.disks.devices.primary.size` in `./machine.nix` to match the card, and, as `root` and with `nix` installed, run:
```bash
 nix run '.#rpi' -- install-system /dev/sdX
```
Then put the card in a PI and boot it.

Alternative to running directly as `root` (esp. if `nix` is not installed for root), the above commands can also be run with `sudo` as additional argument before the `--`.
