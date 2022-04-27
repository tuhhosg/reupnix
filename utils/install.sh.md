#!/usr/bin/env bash
: << '```bash'

# System Installer Script

This script performs the mostly automated installation of any `$HOST` from [`../hosts/`](../hosts/) to the local disk (or image file) `$DISK`.
On a NixOS host, this script can be run by root as: `#` `( cd /etc/nixos/ && nix run .#"$HOST" -- install-system "$DISK" )`.

Doing an installation on non-NixOS, where nix isn't installed for root, is a bit of a hack, but mostly works.
In this case, all `nix` commands will be run as `$SUDO_USER`, but this script and some other user-owned (or user-generated) code will (need to) be run as root.
If that is acceptable, run with `sudo` as first argument: `$` `( cd /etc/nixos/ && nix run .#"$HOST" -- sudo install-system "$DISK" )` (And then maybe `sudo bash -c 'chown $SUDO_USER: '"$DISK"` afterwards.)

The `nix run` in the above commands substitutes a number of `@{`-prefixed variables based on the `$HOST` name and its configuration from [`../hosts/`](../hosts/), and then sources this script and calls the `install-system` function.
If `$DEVICE` points to something in `/dev/`, then it is directly formatted and written to as block device, otherwise `$DEVICE` is (re-)created as raw image and then used as loop device.

Once done, the disk can be transferred -- or the image be copied -- to the final system, and should boot there.
If the hosts hardware target allows, a resulting image can also be passed to [`./functions.sh#register-vbox`](./functions.sh#register-vbox) to create a bootable VirtualBox instance for the current user.
The "Installation" section of each host's documentation should contain host specific details, if any.


## Implementation

```bash
function install-system {( set -eu # 1: blockDev
beQuiet=/dev/null ; if [[ ${debug:=} ]] ; then set -x ; beQuiet=/dev/stdout ; fi

if [[ "$(id -u)" != '0' ]] ; then echo 'Script must be run in a root (e.g. in a »sudo --preserve-env=SSH_AUTH_SOCK -i«) shell.' ; exit ; fi
if [[ ${SUDO_USER:-} ]] ; then function nix {( args=("$@") ; su - "$SUDO_USER" -c "$(declare -p args)"' ; nix "${args[@]}"' )} ; fi

: ${1:?"Required: Target disk or image paths."}

if [[ $debug ]] ; then set +e ; set -E ; trap 'code= ; bash -l || code=$? ; if [[ $code ]] ; then exit $code ; fi' ERR ; fi # On error, instead of exiting straight away, open a shell to allow diagnosing/fixing the issue. Only exit if that shell reports failure (e.g. CtrlC + CtrlD). Unfortunately, the exiting has to be repeated for level of each nested sub-shells.

targetSystem=@{config.system.build.toplevel.outPath}
mnt=/tmp/nixos-install-@{config.networking.hostName} ; mkdir -p "$mnt" ; prepend_trap "rmdir $mnt" EXIT # »mnt=/run/user/0/...« would be more appropriate, but »nixos-install« does not like the »700« permissions on »/run/user/0«


## Get File Systems Ready

partition-disks "$1"
format-partitions
# ... block layers would go here ...
prepend_trap "unmount-system $mnt" EXIT ; mount-system $mnt
if [[ $debug ]] ; then ( set -x ; tree -a -p -g -u -s -D -F --timefmt "%Y-%m-%d %H:%M:%S" $mnt ) ; fi


## Copy Config + Keys

# none for now ...


## Install

for dir in dev/ sys/ run/ ; do mkdir -p $mnt/$dir ; mount tmpfs -t tmpfs $mnt/$dir ; prepend_trap "while umount -l $mnt/$dir 2>$beQuiet ; do : ; done" EXIT ; done # proc/ run/
mkdir -p -m 755 $mnt/nix/var ; mkdir -p -m 1775 $mnt/nix/store
if [[ ${SUDO_USER:-} ]] ; then chown $SUDO_USER: $mnt/nix/store $mnt/nix/var ; fi

( set -x ; time nix copy --no-check-sigs --to $mnt @{config.th.minify.topLevel.outPath:-$targetSystem} )
ln -sT $(realpath $targetSystem) $mnt/run/current-system

if [[ $(cat /run/current-system/system 2>/dev/null || echo "x86_64-linux") != "@{config.preface.hardware}"-linux ]] ; then # cross architecture installation
    mkdir -p $mnt/run/binfmt ; cp -a {,$mnt}/run/binfmt/"@{config.preface.hardware}" || true
    # Ubuntu (by default) expects the "interpreter" at »/usr/bin/qemu-@{config.preface.hardware/-linux/}-static«.
fi

if [[ ${SUDO_USER:-} ]] ; then chown -R root:root $mnt/nix ; chown :30000 $mnt/nix/store ; fi

mount -o bind /nix/store $mnt/nix/store # all the things required to _run_ the system are copied, but (may) need some more things to initially install it
mkdir -p $mnt/boot/EFI/{systemd,BOOT}/ # systemd-boot needs these to exist already
code=0 ; TMPDIR=/tmp LC_ALL=C nixos-install --system @{config.th.minify.topLevel.outPath:-$targetSystem} --no-root-passwd --no-channel-copy --root $mnt --no-bootloader && nixos-enter --root $mnt -c "@{config.system.build.installBootLoader.outPath} $targetSystem" || code=$? #--debug
umount -l $mnt/nix/store

if (( code != 0 )) ; then
    ( set +x ; echo "Something went wrong in the last step of the installation. Inspect the output above and the system mounted in CWD to decide whether it is critical. Exit the shell with 0 to proceed, or non-zero to abort." )
else
    ( set +x ; echo "Installation done, but the system is still mounted in CWD for inspection. Exit the shell to unmount it." )
fi
( cd $mnt ; mnt=$mnt bash -l )

( mkdir -p $mnt/var/lib/systemd/timesync ; touch $mnt/var/lib/systemd/timesync/clock ) || true # save current time

)} #/install-system
