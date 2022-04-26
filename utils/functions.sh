#!/usr/bin/env bash

###
# Library of bash functions, mostly for system installation.
# Most of the functions expect to be called by the install script.
# Individual functions may be run as as: $ nix run /etc/nixos/#$(hostname) -- FUNCTION [...ARGS]
# Or make multiple calls from this shell: $ nix develop /etc/nixos/#$(hostname)
# Or by passing an (inline) script: $ nix run /etc/nixos/#$(hostname) -- -c SCRIPT
###


##
# Partitioning and Formatting
##

## Partitions all »config.installer.disks« to ensure that all (correctly) specified »{config.installer.partitions« exist.
function partition-disks { { # 1: diskPaths
    beQuiet=/dev/null ; if [[ ${debug:=} ]] ; then beQuiet=/dev/stdout ; fi
    declare -g -A blockDevs=( ) # this ends up in the caller's scope
    local path ; for path in ${1/:/ } ; do
        name=${path/=*/} ; if [[ $name != "$path" ]] ; then path=${path/$name=/} ; else name=primary ; fi
        if [[ ${blockDevs[$name]:-} ]] ; then echo "Path for block device $name specified more than once. Duplicate definition: $path" ; exit 1 ; fi
        blockDevs[$name]=$path
    done

    local name ; for name in "@{!config.installer.disks!attrsAsBashEvalSets[@]}" ; do
        if [[ ! ${blockDevs[$name]:-} ]] ; then echo "Path for block device $name not provided" ; exit 1 ; fi
        if [[ ! ${blockDevs[$name]} =~ ^(/dev/.*)$ ]] ; then
            local outFile=${blockDevs[$name]} ; ( set -eu
                eval "@{config.installer.disks!attrsAsBashEvalSets[$name]}" # _size
                install -o root -g root -m 640 -T /dev/null "$outFile" && fallocate -l "$_size" "$outFile"
            ) && blockDevs[$name]=$(losetup --show -f "$outFile") && prepend_trap "losetup -d ${blockDevs[$name]}" EXIT # NOTE: this must not be inside a sub-shell!
        else
            if [[ ! "$(blockdev --getsize64 "${blockDevs[$name]}")" ]] ; then echo "Block device $name does not exist at ${blockDevs[$name]}" ; exit 1 ; fi
            blockDevs[$name]=$(realpath "${blockDevs[$name]}")
        fi
    done

} ; ( set -eu

    for name in "@{!config.installer.disks!attrsAsBashEvalSets[@]}" ; do (
        eval "@{config.installer.disks!attrsAsBashEvalSets[$name]}" # _name ; _size ; _serial ; _alignment ; _mbrParts ; _extraFDiskCommands
        if [[ $_serial ]] ; then
            actual=$(udevadm info --query=property --name="${blockDevs[$name]}" | grep -oP 'ID_SERIAL_SHORT=\K.*')
            if [[ $_serial != "$actual" ]] ; then echo "Block device ${blockDevs[$name]} does not match the serial declared for $name" ; exit 1 ; fi
        fi

        sgdisk --zap-all "${blockDevs[$name]}" >$beQuiet # delete existing part tables
        for partDecl in "@{config.installer.partitionList!listAsBashEvalSets[@]}" ; do (
            eval "$partDecl" # _name ; _disk ; _type ; _size ; _index
            if [[ $_disk != "$name" ]] ; then exit ; fi # i.e. continue
            sgdisk -a "$_alignment" -n 0:+0:+"$_size" -t 0:"$_type" -c 0:"$_name" "${blockDevs[$name]}" >$beQuiet
        ) ; done

        if [[ $_mbrParts ]] ; then
            mbrPartsNum=$(( (${#_mbrParts} + 1) / 2 ))
            sgdisk --hybrid "$_mbrParts" "${blockDevs[$name]}" >$beQuiet # --hybrid: create MBR in addition to GPT; $_mbrParts: make these GPT part 1 MBR parts 2[3[4]]
            printf "
                M                                # edit hybrid MBR
                d;1                              # delete parts 1 (GPT)

                # move the selected »mbrParts« to slots 1[2[3]] instead of 2[3[4]] (by re-creating part1 in the last sector, then sorting)
                n;p;1                            # new ; primary ; part1
                $(( $(blockSectorCount "${blockDevs[$name]}") - 1)) # start (size 1sec)
                x;f;r                            # expert mode ; fix order ; return
                d;$(( (${#_mbrParts} + 1) / 2 + 1 )) # delete ; part(last)

                # create GPT part (spanning primary GPT area) as last part
                n;p;4                            # new ; primary ; part4
                1;33                             # start ; end
                t;4;ee                           # type ; part4 ; GPT

                ${_extraFDiskCommands}
                p;w;q                            # print ; write ; quit
            " | perl -pe 's/^ *| *(#.*)?$//g' | perl -pe 's/\n\n+| *; */\n/g' | fdisk "${blockDevs[$name]}" >$beQuiet
        fi

        partprobe "${blockDevs[$name]}"
    ) ; done
    sleep 1 # sometimes partitions aren't quite made available yet (TODO: wait "for udev to settle" instead?)
)}

## For each filesystem in »config.fileSystems« whose ».device« is in »/dev/disk/by-partlabel/«, this creates the specified file system on that partition.
function format-partitions {( set -eu
    beQuiet=/dev/null ; if [[ ${debug:=} ]] ; then beQuiet=/dev/stdout ; fi
    for fsDecl in "@{config.fileSystems!attrsAsBashEvalSets[@]}" ; do (
        eval "$fsDecl" # _name ; _device ; _fsType ; _formatOptions ; ...
        if [[ $_device != /dev/disk/by-partlabel/* ]] ; then exit ; fi # i.e. continue
        blockDev=$(realpath "$_device") ;  if [[ $blockDev == /dev/sd* ]] ; then
            blockDev=$( shopt -s extglob ; echo "${blockDev%%+([0-9])}")
        else
            blockDev=$( shopt -s extglob ; echo "${blockDev%%p+([0-9])}")
        fi
        if [[ ' '"${blockDevs[@]}"' ' != *' '"$blockDev"' '* ]] ; then echo "Partition alias $_device does not point at one of the target disks ${blockDevs[@]}" ; exit 1 ; fi
        mkfs.${_fsType} ${_formatOptions} "${_device}" >$beQuiet
        partprobe "${_device}"
    ) ; done
)}

## Mounts all file systems as it would happen during boot, but at path prefix »$mnt«.
function mount-system {( set -eu # 1: mnt, 2?: fstabPath
    # mount --all --fstab @{config.system.build.toplevel.outPath}/etc/fstab --target-prefix "$1" -o X-mount.mkdir # (»--target-prefix« is not supported on Ubuntu 20.04)
    mnt=$1 ; fstabPath=${2:-"@{config.system.build.toplevel.outPath}/etc/fstab"}
    <$fstabPath grep -v '^#' | LC_ALL=C sort -k2 | while read source target type options numbers ; do
        if [[ ! $target || $target == none ]] ; then continue ; fi
        options=,$options, ; options=${options//,ro,/,}
        if [[ $options =~ ,r?bind, ]] ; then continue ; fi # TODO: also rbind?
        if ! mountpoint -q "$mnt"/"$target" ; then
            mkdir -p "$mnt"/"$target"
            mount -t $type -o "${options:1:(-1)}" "$source" "$mnt"/"$target"
        fi
    done
    # Since bind mounts may depend on other mounts not only for the target (which the sort takes care of) but also for the source, do all bind mounts last. This would break if there was a different bind mountpoint within a bind-mounted target.
    <$fstabPath grep -v '^#' | LC_ALL=C sort -k2 | while read source target type options numbers ; do
        if [[ ! $target || $target == none ]] ; then continue ; fi
        options=,$options, ; options=${options//,ro,/,}
        if [[ ! $options =~ ,r?bind, ]] ; then continue ; fi # TODO: also rbind?
        if ! mountpoint -q "$mnt"/"$target" ; then
            mkdir -p "$mnt"/"$target"
            source=$mnt/$source ; if [[ ! -e $source ]] ; then mkdir -p "$source" ; fi
            mount -t $type -o "${options:1:(-1)}" "$source" "$mnt"/"$target"
        fi
    done
)}

## Unmounts all file systems (that would be mounted during boot / by »mount-system«).
function unmount-system {( set -eu # 1: mnt, 2?: fstabPath
    mnt=$1 ; fstabPath=${2:-"@{config.system.build.toplevel.outPath}/etc/fstab"}
    <$fstabPath grep -v '^#' | LC_ALL=C sort -k2 -r | while read source target rest ; do
        if [[ ! $target || $target == none ]] ; then continue ; fi
        if mountpoint -q "$mnt"/"$target" ; then
            umount "$mnt"/"$target"
        fi
    done
)}


##
# Maintenance
##

## On the host and for the user it is called by, creates/registers a VirtualBox VM meant to run the shells target host. Requires the path to the target host's »diskImage« as the result of running the install script. The image file may not be deleted or moved. If »bridgeTo« is set (to a host interface name, e.g. as »eth0«), it is added as bridged network "Adapter 2" (which some hosts need).
function register-vbox {( set -eu # 1: diskImage, 2?: bridgeTo
    diskImage=$1 ; bridgeTo=${2:-}
    vmName="nixos-@{config.networking.hostName}"

    if [[ ! -e $diskImage.vmdk ]] ; then
        VBoxManage internalcommands createrawvmdk -filename $diskImage.vmdk -rawdisk $diskImage # pass-through
    fi

    VBoxManage createvm --name "$vmName" --register --ostype Linux26_64
    VBoxManage modifyvm "$vmName" --memory 2048 --pae off --firmware efi

    VBoxManage storagectl "$vmName" --name SATA --add sata --portcount 4 --bootable on --hostiocache on
    VBoxManage storageattach "$vmName" --storagectl SATA --port 0 --device 0 --type hdd --medium $diskImage.vmdk

    if [[ $bridgeTo ]] ; then # VBoxManage list bridgedifs
        VBoxManage modifyvm "$vmName" --nic2 bridged --bridgeadapter2 $bridgeTo
    fi

    VBoxManage modifyvm "$vmName" --uart1 0x3F8 4 --uartmode1 server /run/user/$(id -u)/$vmName.socket # (guest sets speed)

    set +x # avoid double-echoing
    echo '# VM info:'
    echo " VBoxManage showvminfo $vmName"
    echo '# start VM:'
    echo " VBoxManage startvm $vmName --type headless"
    echo '# kill VM:'
    echo " VBoxManage controlvm $vmName poweroff"
    echo '# create TTY:'
    echo " socat UNIX-CONNECT:/run/user/$(id -u)/$vmName.socket PTY,link=/run/user/$(id -u)/$vmName.pty"
    echo '# connect TTY:'
    echo " screen /run/user/$(id -u)/$vmName.pty"
    echo '# screenshot:'
    echo " ssh $(hostname) VBoxManage controlvm $vmName screenshotpng /dev/stdout | display"
)}


##
# Utilities
##

## Prepends a command to a trap. Especially useful fo define »finally« commands via »prepend_trap '<command>' EXIT«.
#  NOTE: When calling this in a sub-shell whose parents already has traps installed, make sure to do »trap - trapName« first. On a new shell, this should be a no-op, but without it, the parent shell's traps will be added to the sub-shell as well (due to strange behavior of »trap -p« (in bash ~5.1.8)).
prepend_trap() { # 1: command, ...: trapNames
    fatal() { printf "ERROR: $@\n" >&2 ; return 1 ; }
    local cmd=$1 ; shift || fatal "${FUNCNAME} usage error"
    local name ; for name in "$@" ; do
        trap -- "$( set +x
            printf '%s\n' "( ${cmd} ) || true ; "
            p3() { printf '%s\n' "${3:-}" ; } ; eval "p3 $(trap -p "${name}")"
        )" "${name}" || fatal "unable to add to trap ${name}"
    done
} ; declare -f -t prepend_trap # required to modify DEBUG or RETURN traps

## Given a block device path, returns the number of 512byte sectors it can hold.
function blockSectorCount { printf %s "$(( $(blockdev --getsize64 "$1") / 512 ))" ; }
