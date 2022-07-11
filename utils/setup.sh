
##
# Host Setup Scripts
##

# This project largely uses the default setup scripts of »wiplib«, see https://github.com/NiklasGollenstede/nix-wiplib/tree/master/lib/setup-scripts

# Since the store contents is already copied, calling the bootloader installer is enough to complete the system "installation":
function nixos-install-cmd {( set -eu # 1: mnt, 2: topLevel
    ( PATH=@{config.systemd.package}/bin:$PATH ; set -x ; nixos-enter --root $mnt -c "@{config.system.build.installBootLoader} $targetSystem" ) #--debug
)}
