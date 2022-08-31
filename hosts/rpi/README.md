
# Raspberry Pi Target

Test configuration of a Raspberry PI 4 as target device.


## Installation

To prepare the microSD card, adjust the `fs.disks.devices.primary.size` in `./machine.nix` to match the card, and, as `root` and with `nix` installed, run:
```bash
 nix run '.#rpi' -- install-system /dev/sdX
```
Then put the card in a PI and boot it.

Alternative to running directly as `root` (esp. if `nix` is not installed for root), the above commands can also be run with `sudo` as additional argument before the `--`.

To see the serial console during boot, connect the RXD pin of a 3.3V UART adapter to pin 08 (GPIO14 -- TXD) of the PI, TXD to pin 10 (GPIO15 -- RXD), and ground to ground. Then, before booting the PI, run this on the host where the other (USB) end of the adapter is plugged in:
```bash
nix-shell -p tio --run 'tio /dev/ttyUSB2' # (tio uses the correct settings by default)
```

**NOTE**: Booting the PI currently stalls multiple times if an HDMI screen is connected (do don't connect one).
