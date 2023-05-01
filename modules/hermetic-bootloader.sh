
function include-path {( set -eu ; # 1: path
    if [[ -L $tree/$1 ]] ; then
        if [[ $( readlink $tree/"$1" ) != "$1" ]] ; then echo "Link $1 exists and does not point at the expected target!" ; exit 1 ; fi
    elif [[ ! -e $1 ]] ; then
        echo "Path $1 can't be included because it doesn't exist!" ; exit 1
    else
        if [[ "$1" == */* ]] ; then mkdir -p "$( dirname $tree/"$1" )" ; fi
        ln -sT "$1" $tree/"$1"
    fi
)}

function write-file {( set -eu ; # 1: path, 2: content
    mkdir -p $tree/"$(dirname "$1")"
    printf %s "$2" > $tree/"$1"
)}

function config-uboot-extlinux {( set -eu ; # 1: default
    config=$'\nMENU TITLE ------------------------------------------------------------\n'
    if [[ @{config.boot.loader.timeout} == 0 ]] ; then
        config+=$'TIMEOUT 1\n' # near-instantaneous
    else
        config+="TIMEOUT $(( @{config.boot.loader.timeout:-0} * 10 ))"$'\n'
    fi
    for name in "@{!cfg.entries[@]}" ; do
        eval 'declare -A entry='"@{cfg.entries[$name]}"
        config+="
LABEL ${entry[id]}
  MENU LABEL ${entry[title]} (${entry[id]})
  LINUX ${entry[kernel]}
  INITRD ${entry[initrd]}
  APPEND ${entry[cmdline]}
  ${entry[deviceTree]:+"FDTDIR ${entry[deviceTree]}"}
"
    done
    write-file /extlinux/extlinux.conf "${1:+"DEFAULT $1"}"$'\n'"$config"
    for name in "@{!cfg.entries[@]}" ; do
        eval 'declare -A entry='"@{cfg.entries[$name]}"
        write-file /extlinux/entries/"${entry[id]}".conf "DEFAULT ${entry[id]}"$'\n'"$config"
    done
)}


function config-systemd-boot {( set -eu ; # 1: default
    write-file /loader/loader.conf "
@{config.boot.loader.timeout:+timeout @{config.boot.loader.timeout}}
${1:+"default $1.conf"}
editor 0
console-mode keep
"
    for name in "@{!cfg.entries[@]}" ; do
        eval 'declare -A entry='"@{cfg.entries[$name]}"
        write-file /loader/entries/"${entry[id]}".conf "
title ${entry[title]}
version ${entry[id]}
linux ${entry[kernel]}
initrd ${entry[initrd]}
options ${entry[cmdline]}
${entry[machine-id]:+"machine-id ${entry[machine-id]}"}
"
    done
)}

function build-tree {( set -eu ; # (void)
    for name in "@{!cfg.entries[@]}" ; do
        eval 'declare -A entry='"@{cfg.entries[$name]}"
        include-path ${entry[kernel]}
        include-path ${entry[initrd]}
        [[ ! ${entry[deviceTree]:-} ]] || include-path ${entry[deviceTree]}
    done
    default=@{cfg.default:-} ; if [[ $default && @{cfg.entries[$default]:-} ]] ; then
        eval 'declare -A entry='"@{cfg.entries[$default]}"
        default=${entry[id]}
    fi
    if [[ @{cfg.loader} == uboot-extlinux ]] ; then
        config-uboot-extlinux "$default"
    fi
    if [[ @{cfg.loader} == systemd-boot ]] ; then
        config-systemd-boot "$default"
        arch=x64 ; if [[ @{pkgs.system} == aarch64-* ]] ; then arch=aa64 ; fi
        mkdir -p $tree/EFI/systemd ; ln -sT @{pkgs.systemd}/lib/systemd/boot/efi/systemd-boot${arch}.efi $tree/EFI/systemd/systemd-boot${arch}.efi
        mkdir -p $tree/EFI/BOOT    ; ln -sT @{pkgs.systemd}/lib/systemd/boot/efi/systemd-boot${arch}.efi $tree/EFI/BOOT/BOOT${arch^^}.EFI
    fi
    for path in "@{!cfg.extraFiles[@]}" ; do
        mkdir -p $tree/"$(dirname "$path")" ; ln -sT "@{cfg.extraFiles[$path]}" $tree/"$path"
    done
)}

function write-to-fs {( set -eu ; # 1: tree, 2: root, 3?: selfRef
    tree=$1 ; root=$2 ; selfRef=${3:-} ; existing=( )
    while IFS= read -r -d $'\0' path ; do
        if [[ -e $root/$path ]] ; then
            existing+=( "$path" ) ; continue
        fi
        @{pkgs.coreutils}/bin/mkdir -p "$root"/"$( @{pkgs.coreutils}/bin/dirname "$path" )"
        @{pkgs.coreutils}/bin/cp -T $tree/"$path" "$root"/"$path"
    done < <( cd $tree ; @{pkgs.findutils}/bin/find -L . -type f,l -print0 )
    for path in "${existing[@]}" ; do
        if [[ $( cd $tree ; @{pkgs.coreutils}/bin/shasum "$path" ) != $( cd "$root" ; @{pkgs.coreutils}/bin/shasum "$path" ) ]] ; then
            @{pkgs.coreutils}/bin/rm "$root"/"$path" ; @{pkgs.coreutils}/bin/cp -T $tree/"$path" "$root"/"$path"
        fi
    done
    # TODO: delete unneeded old files/dirs
    if [[ $selfRef ]] ; then
        id=default-${selfRef:11:8}
        function replace {
            path=$1 ; str=$( @{pkgs.coreutils}/bin/cat "$path" ) ; prev="$str"
            str=${str//@default-self@/$id}
            str=${str//@toplevel@/$selfRef}
            [[ $str == "$prev" ]] || ( <<< "$str" @{pkgs.coreutils}/bin/cat >"$path" )
        }
        base=loader ; if [[ @{cfg.loader} == uboot-extlinux ]] ; then base=extlinux ; fi
        while IFS= read -r -d $'\0' path ; do replace "$path" ; done < <( @{pkgs.findutils}/bin/find -L "$root"/$base/ -type f,l -print0 )
        [[ ! -e "$root"/$base/entries/"@default-self@".conf ]]  || mv "$root"/$base/entries/{"@default-self@","$id"}.conf
        <<< "$selfRef" @{pkgs.coreutils}/bin/cat > "$root"/toplevel
    fi
)}

function write-boot-partition {( set -u # 1: tree, 2: blockDev, 3: label, 4?: selfRef
    tree=$1 ; blockDev=$2 ; label=$3 ; selfRef=${4:-}
    # TODO: is it possible to just "flash" an empty FAT32? The label can be replaced with dd ...
    @{pkgs.dosfstools}/bin/mkfs.vfat -n "$label" "$blockDev" &1>/dev/null || @{pkgs.dosfstools}/bin/mkfs.vfat -n "$label" "$blockDev" || exit
    root=$( @{pkgs.coreutils}/bin/mktemp -d ) ; mount "$blockDev" $root ; trap "umount $root ; @{pkgs.coreutils}/bin/rmdir $root" EXIT || exit
    write-to-fs $tree "$root" "$selfRef" || exit
)}

function get-parent-disk {( set -u # 1: partition
    export PATH=@{pkgs.coreutils}/bin
    arg=$( realpath "$1" ) || exit
    arg=$( basename "$arg" ) || exit
    arg=$( readlink -f /sys/class/block/"$arg"/.. ) || exit
    arg=$( basename "$arg" ) || exit
    echo /dev/"$arg"
)}

function activate-as-slot {( set -eu ; # 1: tree, 2: index, 3: label, 4?: selfRef
    tree=$1 ; index=$2 ; label=$3 ; selfRef=${4:-}
    hash=@{config.networking.hostName!hashString.sha256:0:8}

    write-boot-partition $tree "/dev/disk/by-partlabel/boot-${index}-${hash}" "$label" "$selfRef"

    disk=$( get-parent-disk "/dev/disk/by-partlabel/boot-1-${hash}" ) # (can't reference to disks by partlabel)
    for (( i = 2 ; i <= @{cfg.slots.number} ; i++ )) ; do
        if [[ $( get-parent-disk "/dev/disk/by-partlabel/boot-${i}-${hash}" ) != "$disk" ]] ; then echo "boot slot $i is on unexpected parent disk" ; exit 1 ; fi
    done

    diskSize=$( @{pkgs.util-linux}/bin/blockdev --getsize64 "$disk" ) # TODO: could take this from the disk specification

    #  The behavior might be slightly (EFI-)implementation-dependent, but with a working primary header, the secondary should not be used. (The spec (https://uefi.org/sites/default/files/resources/UEFI_Spec_2_8_final.pdf, page 120) says that the last step in checking that "a GPT" is valid is to check that the AlternateLBA "is a valid GPT" (without addressing the recursion there). It does not require that the two headers point at each other (here) or that they otherwise match ...)
    #  The spec says to update the secondary (backup) header first.
    @{pkgs.coreutils}/bin/dd status=none conv=notrunc bs=512 skip=2 seek=$(( diskSize / 512 - 1 )) count=1 if=@{config.wip.fs.disks.partitioning}/"@{cfg.slots.disk}".slot-${index}.backup of="$disk"

    if [[ @{cfg.loader} != uboot-extlinux ]] ; then
        @{pkgs.coreutils}/bin/dd status=none conv=notrunc bs=512  skip=1 seek=1                     count=1 if=@{config.wip.fs.disks.partitioning}/"@{cfg.slots.disk}".slot-${index}.backup of="$disk"
    else
        @{pkgs.coreutils}/bin/dd status=none conv=notrunc bs=1024 skip=0 seek=0                     count=1 if=@{config.wip.fs.disks.partitioning}/"@{cfg.slots.disk}".slot-${index}.backup of="$disk"
        # For systems that actually use both MBR and GPU (rPI with uboot), this assumes/requires writing two logical sectors to be atomic ...
    fi
)}

function build-out {( set -eu ; # (void)
    printf %s "#!@{pkgs.bash}/bin/bash -eu
# 1: slot, 2?: selfRef, ...: ignored
$( declare -f write-to-fs write-boot-partition get-parent-disk activate-as-slot )
$( declare -p pkgs_findutils pkgs_util0linux pkgs_coreutils pkgs_dosfstools )
$( declare -p config_wip_fs_disks_partitioning config_networking_hostName1hashString_sha256 cfg_loader cfg_slots_number cfg_slots_disk )
activate-as-slot $tree \"\$1\" '@{cfg.slots.currentLabel}' \"\${2:-}\"
" > $out
    chmod +x $out
)}

function apply-partitionings {( set -eu ; # (void)
    hash=@{config.networking.hostName!hashString.sha256:0:8}

    disk=$( get-parent-disk "/dev/disk/by-partlabel/boot-1-${hash}" )
    for (( i = 2 ; i <= @{cfg.slots.number} ; i++ )) ; do
        if [[ $( get-parent-disk "/dev/disk/by-partlabel/boot-${i}-${hash}" ) != "$disk" ]] ; then echo "boot slot $i is on unexpected parent disk" ; exit 1 ; fi
    done
    for (( i = 1 ; i <= @{cfg.slots.number} ; i++ )) ; do
        @{pkgs.gptfdisk}/bin/sgdisk --load-backup=@{config.wip.fs.disks.partitioning}/"@{cfg.slots.disk}".slot-${i}.backup "$disk" &>/dev/null
    done
)}

function build-init {( set -eu ; # (void)
    printf %s "#!@{pkgs.bash}/bin/bash -eu
# ...: outArgs
$( declare -f get-parent-disk apply-partitionings )
$( declare -p pkgs_coreutils pkgs_gptfdisk )
$( declare -p config_wip_fs_disks_partitioning config_networking_hostName1hashString_sha256 cfg_slots_number cfg_slots_disk )
apply-partitionings
source $out
disk=\$( get-parent-disk /dev/disk/by-partlabel/boot-1-@{config.networking.hostName!hashString.sha256:0:8} )
@{pkgs.parted}/bin/partprobe \$disk &>/dev/null && @{config.systemd.package}/bin/udevadm settle -t 15 || true
" > $init
    chmod +x $init
)}

#set -x

build-tree
build-out
build-init
