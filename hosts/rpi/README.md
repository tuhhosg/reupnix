
# Raspberry Pi Target

Test configuration of a Raspberry PI 4 as target device.


## Installation

To prepare the **microSD card** (for other boot media, see below), adjust the `fs.disks.devices.primary.size` in `./machine.nix` to match the card, and, as `root` and with `nix` installed, run:
```bash
 nix run '.#rpi' -- install-system /dev/sdX
```
Then put the card in a PI and boot it.

Alternative to running directly as `root` (esp. if `nix` is not installed for root), the above commands can also be run with `sudo` as additional argument before the `--`.

To see the serial console during boot, connect the RXD pin of a 3.3V UART adapter to pin 08 (GPIO14 -- TXD) of the PI, TXD to pin 10 (GPIO15 -- RXD), and ground to ground. Then, before booting the PI, run this on the host where the other (USB) end of the adapter is plugged in:
```bash
nix-shell -p tio --run 'tio /dev/ttyUSBx' # (tio uses the correct settings by default)
```


### Other Boot Media

To boot from something other than a microSD (or eMMC on a CM), some things would need to be adjusted:
* The eeprom has to have the medium in its boot order. Newer rPI4 have this by default.
* u-boot has to load its "env" from the boot medium, which is required to work to switch to other system configurations. For microSD/eMMC, this is configured via the build-time defines `CONFIG_ENV_IS_IN_MMC=y` and `CONFIG_SYS_MMC_ENV_DEV=X`.
* The `bootcmd` in u-boot's env has to use the correct device. For a USB SSD, this would be: `sysboot usb 0:1 fat ${scriptaddr} /extlinux/extlinux.conf`.
* The kernel may need additional features/modules (in the initrd) to open the device.
