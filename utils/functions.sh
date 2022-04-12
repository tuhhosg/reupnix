#!/usr/bin/env bash

###
# Library of bash functions, mostly for system installation.
# Most of the functions expect to be called by the install script.
# Individual functions may be run as as: $ nix run /etc/nixos/#$(hostname) -- FUNCTION [...ARGS]
# Or make multiple calls from this shell: $ nix develop /etc/nixos/#$(hostname)
# Or by passing an (inline) script: $ nix run /etc/nixos/#$(hostname) -- -c SCRIPT
# Those functions that don't use any »setup_*« variable may alternatively be called directly after »source«ing this script.
###

# When »source«ing this, »$config« should already be set (otherwise this may set it wrong, as »$0« is not as expected):
: ${config:="$(dirname -- "$(cd "$(dirname -- "$0")" ; pwd)")"}


## Downloads, directly uncompresses, and flashes an image to a block device. This may seem to be stuck at 100% if writing takes longer than reading/downloading.
#  Parameters:
#  1: An HTTP(S) URL to download the image from, or a path to a local file.
#  2: The block device to be (over!)written with the uncompressed image.
function flash-image {( set -eu # 1: imgUrl, 2: blockDev
    imgUrl="$1" ; blockDev="$2" ;
    case "$imgUrl" in
        http?://*) fetchCmd='wget -qO-' ;;
        *)         fetchCmd=cat
    esac
    case "$imgUrl" in
        *.zip) unzipCmd='busybox unzip - -p' ;;
        *.xz)  unzipCmd='xzcat -' ;;
        *.zst) unzipCmd='zstdcat' ;;
        *)     unzipCmd=cat
    esac
    $fetchCmd "$imgUrl" | pv | $unzipCmd >"$blockDev"
    partprobe "$blockDev" ; sleep 1 # wait for partitions to update
)}

## Copies this nixos config onto the (local or remote) FS mounted at »$targetRoot«.
function copy-nixos-config {( set -eu # 1: targetRoot, ...: rsyncFlags
    targetRoot="$1" ; shift # (uid 0 is root, gid 1 is pinned as wheel/sudo)
    rsync --archive --update --delete --times --checksum --inplace --no-whole-file --chown='0:1' --chmod=g-w \
        --exclude='/.git' --exclude-from="$config"/'.gitignore' "$@" "$config"/ "$targetRoot"/persist/etc/nixos/
)}

## Copies the nixos config from »$config« into »/persist/« in the FS mounted at »$mnt, and links it to »/etc/nixos«.
function setup-nixos-config {( set -eu # 1: mnt
    if [[ -L "$1"/etc/nixos ]] ; then rm "$1"/etc/nixos ; fi
    mkdir -p -- "$1"/etc/ "$1"/persist/etc/
    ln -sfT ../../persist/etc/nixos/ "$1"/etc/nixos
    copy-nixos-config "$1" "$@" # copy and config
)}

## Makes a mount point that is read-only when not mounted.
function mkmnt {( set -eu # 1: path
    if mountpoint -q "$1" ; then return 1 ; fi
    if [[ "$(ls -A "$1" >/dev/null 2>&1 || true)" ]] ; then return 1 ; fi
    mkdir -p -- "$1" ; if [[ "$(stat -c '%a' "$1")" != '0' ]] ; then chmod 000 "$1" ; fi ; #chattr +i "$1" || true # (fails on tmpfs) # (making them immutable is rather pointless since most will end up on volatile datasets)
)}

## Changes permissions and owner of the target. Creates it as directory if not existing.
function chpem {( set -eu # 1: permissions, 2: owner, 3: path
    if [[ ! -e "$3" ]] ; then mkdir -p -- $3 ; fi
    chmod -- "$1" "$3" ; chown -- "$2" "$3"
)}

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


##
# Disk Keys
##

## Writes a »$name«d secret from stdin to »$targetDir«, ensuring proper file permissions.
#  Strips (any number of) tailing newlines
function write-secret {( set -eu # 1: path, 2?: owner[:[group]], 3?: permissions
    secret=$(cat) ; if [[ "${#secret}" == 0 ]] ; then exit 1 ; fi # TODO: »$()« strips tailing newlines
    mkdir -p -- "$(dirname "$1")"/
    #owner=${2:-root} ; group=root ; if [[ $owner == *:* ]] ; then group=${owner/*:/} ; owner=${owner/:$group/} ; if [[ ! $group ]] ; then group=$owner ; fi ; fi
    #install -o "$owner" -g "$group" -m "${3:-400}" -T /dev/null "$1"
    install -o root -g root -m 000 -T /dev/null "$1"
    <<< "$secret" head -c -1 >"$1" # (<<< ensures a tailing a $'\n')
    chown "${2:-root:root}"   "$1"
    chmod "${3:-400}"         "$1"
)}

## Creates a random static key on a new key partition on the GPT partitioned »$blockDev«.
#  To create/clear the GPT: $ sgdisk --zap-all "$blockDev"
function add-bootkey-to-keydev {( set -eu # 1: blockDev, 2?: hostHash
    blockDev=$1 ; hostHash=${2:-$setup_hostHash}
    bootkeyPartlabel=bootkey-${hostHash:0:16}
    sgdisk --new=0:0:+1 --change-name=0:"$bootkeyPartlabel" --typecode=0:8301 "$blockDev" # create new 1 sector (512b) partition
    partprobe "$blockDev" ; sleep 1 # wait for partitions to update
    </dev/urandom tr -dc 0-9a-f | head -c 512 >/dev/disk/by-partlabel/"$bootkeyPartlabel"
)}

## Puts an empty key in the keystore, causing that ZFS dataset to be unencrypted, even if it's parent is encrypted.
function genkey-unencrypted {( set -eu # 1: usage
    keystore=/run/keystore-${setup_hostHash:0:8} ; usage=$1
    write-secret "$keystore"/"$usage".key <<<''
)}

## "Generates" a key by copying the hostname to the keystore.
function genkey-hostname {( set -eu # 1: usage
    keystore=/run/keystore-${setup_hostHash:0:8} ; usage=$1
    if [[ ! "$usage" =~ ^(luks/keystore/.*)$ ]] ; then printf '»trivial« key mode is only available for the keystore itself.\n' ; exit 1 ; fi
    write-secret "$keystore"/"$usage".key <<<"$setup_hostName"
)}

## "Generates" a key by copying it from a bootkey partition (see »add-bootkey-to-keydev«) to the keystore.
function genkey-usb-part {( set -eu # 1: usage
    keystore=/run/keystore-${setup_hostHash:0:8} ; usage=$1
    if [[ ! "$usage" =~ ^(luks/keystore/.*)$ ]] ; then printf '»usb-part« key mode is only available for the keystore itself.\n' ; exit 1 ; fi
    bootkeyPartlabel=bootkey-"${setup_hostHash:0:16}"
    cat /dev/disk/by-partlabel/"$bootkeyPartlabel" | write-secret "$keystore"/"$usage".key
)}

## "Generates" a key by copying a different key from the keystore to the keystore.
function genkey-copy {( set -eu # 1: usage, 2: source
    keystore=/run/keystore-${setup_hostHash:0:8} ; usage=$1 ; source=$2
    cat "$keystore"/"$source".key | write-secret "$keystore"/"$usage".key
)}

## "Generates" a key by writing a constant value to the keystore.
function genkey-constant {( set -eu # 1: usage, 2: value
    keystore=/run/keystore-${setup_hostHash:0:8} ; usage=$1 ; value=$2
    write-secret "$keystore"/"$usage".key <<<"$value"
)}

## "Generates" a key by prompting for a password and saving it to the keystore.
function genkey-password {( set -eu # 1: usage
    keystore=/run/keystore-${setup_hostHash:0:8} ; usage=$1
    read -s -p "Please enter the password as key for $setup_hostName/$usage: " password1
    read -s -p "Please enter the same password again: " password2
    if [[ "$(shasum <<<"$password1")" != "$(shasum <<<"$password2")" ]] ; then printf 'Passwords mismatch, aborting.\n' ; exit 1 ; fi
    write-secret "$keystore"/"$usage".key <<<"$password1"
)}

## Generates a key by prompting for a password, combining it with »$keystore/home.key«, and saving it to the keystore.
function genkey-home-pw {( set -eu # 1: usage, 2: user
    keystore=/run/keystore-${setup_hostHash:0:8} ; usage=$1 ; user=$2
    if  [[ ${!userPasswords[@]} && ${userPasswords[$user]:-} ]] ; then
        password=${userPasswords[$user]}
    else
        read -s -p "Please enter the user password that will be used as part of the key for $setup_hostName/$usage: " password1
        read -s -p "Please enter the same password again: " password2
        if [[ "$(shasum <<<"$password1")" != "$(shasum <<<"$password2")" ]] ; then printf 'Passwords mismatch, aborting.\n' ; exit 1 ; fi
        password=$password1
    fi
    key=$( ( cat "$keystore"/home/"$user".key && cat <<<"$password" ) | sha256sum | head -c 64 )
    write-secret "$keystore"/"$usage".key <<<"$key"
)}

## Generates a reproducible secret for a certain »$use«case by prompting for a pin/password and then challenging slot »$slot« of YubiKey »$serial«, and saves it to the »$keystore«.
function genkey-yubikey-pin {( set -eu # 1: usage, 2: serialAndSlot(as »serial:slot«)
    usage=$1 ; serialAndSlot=$2
    read -s -p "Please enter the pin/password as challenge to YubiKey »$serialAndSlot« as key for $setup_hostName/$usage: " password1
    read -s -p "Please enter the same pin/password again: " password2
    if [[ "$(shasum <<<"$password1")" != "$(shasum <<<"$password2")" ]] ; then printf 'Passwords mismatch, aborting.\n' ; exit 1 ; fi
    genkey-yubikey-challenge "$usage" "$serialAndSlot:$password1" true
)}

## Generates a reproducible secret for a certain »$use«case on a »$host« by challenging slot »$slot« of YubiKey »$serial«, and saves it to the »$keystore«.
function genkey-yubikey {( set -eu # 1: usage, 2: serialAndSlot(as »serial:slot«)
    usage=$1 ; serialAndSlot=$2
    usage_="$usage" ; if [[ "$usage" =~ ^(luks/.*/[0-8])$ ]] ; then usage_="${usage:0:(-2)}" ; fi # produce the same secret, regardless of the target luks slot
    challenge="$setup_hostName:$usage_:$setup_incarnation"
    genkey-yubikey-challenge "$usage" "$serialAndSlot:$challenge"
)}

## Generates a reproducible secret for a certain »$use«case by challenging slot »$slot« of YubiKey »$serial« with the fixed »$challenge«, and saves it to the »$keystore«.
#  If »$sshArgs« is set as (env) var, generate the secret locally, then use »ssh $sshArgs« to write the secret on the other end.
#  E.g.: # sshArgs='installerIP' genkey-yubikey /run/keystore/ zfs/rpool/remote 1234567:2:customChallenge
function genkey-yubikey-challenge {( set -eu # 1: usage, 2: serialAndSlotAndChallenge(as »$serial:$slot:$challenge«), 3: onlyOnce
    keystore=/run/keystore-${setup_hostHash:0:8} ; usage=$1 ; args=$2
    serial=$(<<<"$args" cut -d: -f1)
    slot=$(<<<"$args" cut -d: -f2)
    challenge=${args/$serial:$slot:/}

    if [[ "$serial" != "$(ykinfo -sq)" ]] ; then printf 'Please insert / change to YubiKey with serial %s!\n' "$serial" ; fi
    if [[ ! "${3:-}" ]] ; then
        read -p 'Challenging YubiKey '"$serial"' slot '"$slot"' twice with challenge »'"$challenge"':1/2«. Enter to continue, or Ctrl+C to abort:'
    else
        read -p 'Challenging YubiKey '"$serial"' slot '"$slot"' once with challenge »'"$challenge"'«. Enter to continue, or Ctrl+C to abort:'
    fi
    if [[ "$serial" != "$(ykinfo -sq)" ]] ; then printf 'YubiKey with serial %s not present, aborting.\n' "$serial" ; exit 1 ; fi

    if [[ ! "${3:-}" ]] ; then
        secret="$(ykchalresp -"$slot" "$challenge":1)""$(ykchalresp -2 "$challenge":2)"
        if [[ ${#secret} != 80 ]] ; then printf 'YubiKey challenge failed, aborting.\n' "$serial" ; exit 1 ; fi
    else
        secret="$(ykchalresp -"$slot" "$challenge")"
        if [[ ${#secret} != 40 ]] ; then printf 'YubiKey challenge failed, aborting.\n' "$serial" ; exit 1 ; fi
    fi
    if [[ ! "${sshArgs:-}" ]] ; then
        ( head -c 64 | write-secret "$keystore"/"$usage".key ) <<<"$secret"
    else
        read -p 'Uploading secret with »ssh '"$sshArgs"'«. Enter to continue, or Ctrl+C to abort:'
        ( head -c 64 | ssh $sshArgs /etc/nixos/utils/functions.sh write-secret "$keystore"/"$usage".key ) <<<"$secret"
    fi
)}

## Generates a random secret key and saves it to the keystore.
function genkey-random {( set -eu # 1: usage
    keystore=/run/keystore-${setup_hostHash:0:8} ; usage=$1
    </dev/urandom tr -dc 0-9a-f | head -c 64 | write-secret "$keystore"/"$usage".key
)}

## Generates a secret for a certain »$use«case using the generation method »$from« some other key.
function genkey-inherit {( set -eu # 1: usage, 2: from
    usage=$1 ; from=$2

    methodAndOptions="${setup_cryptKeys[$from]}"
    method=$(<<<"$methodAndOptions" cut -d= -f1)
    options=${methodAndOptions/$method=/} # TODO: if no options are provided, this passes the method string as options (use something like ${methodAndOptions:(- $(( ${#method} + 1 ))})

    genkey-"$method" "$usage" "$options"
)}

## Interactively prompts for a password to be entered and confirmed.
function prompt-new-password {( set -eu # 1: usage
    usage=$1
    read -s -p "Please enter the new password for $usage: " password1
    read -s -p "Please enter the same password again: " password2
    if [[ "$(shasum <<<"$password1")" != "$(shasum <<<"$password2")" ]] ; then printf 'Passwords mismatch, aborting.\n' ; exit 1 ; fi
    cat <<<"$password1"
)}


##
# Communication Keys
##

## Copies SSH public key(s) »$authorized_keys« for »$userName« on the FS mounted at »$mountPath«.
function write-authorized_keys {( set -eu # 1: mountPath, 2: userName, 3: authorized_keys
    if [[ "$2" == 'root' ]] ; then home=root ; else home=home/"$2" ; fi
    # TODO: without chown'ing to the correct U/GIDs, does this even work for any user other than root?
    mkdir -p -- "$1"/"$home"/.ssh/ ; chmod -- 700 "$1"/"$home"/.ssh
    touch "$1"/"$home"/.ssh/authorized_keys ; chmod 600 "$1"/"$home"/.ssh/authorized_keys
    printf '%s\n' "${3}}" >"$1"/"$home"/.ssh/authorized_keys
)}

## Creates the default SSHd host keys on the FS mounted at »$mountPath«.
function create-host-keys {( set -eu # 1: mountPath
    mkdir -p -- "$1"/persist/etc/ssh/ ;                  mkdir -p -- "$1"/etc/ssh/
    ln -sfT    ../../persist/etc/ssh/ssh_host_ed25519_key            "$1"/etc/ssh/ssh_host_ed25519_key
    ln -sfT    ../../persist/etc/ssh/ssh_host_ed25519_key.pub        "$1"/etc/ssh/ssh_host_ed25519_key.pub
    ln -sfT    ../../persist/etc/ssh/ssh_host_ed25519_key-cert.pub   "$1"/etc/ssh/ssh_host_ed25519_key-cert.pub
    ln -sfT    ../../persist/etc/ssh/ssh_host_rsa_key                "$1"/etc/ssh/ssh_host_rsa_key
    ln -sfT    ../../persist/etc/ssh/ssh_host_rsa_key.pub            "$1"/etc/ssh/ssh_host_rsa_key.pub
    if [[ ! -e "$1"'/persist/etc/ssh/ssh_host_ed25519_key' ]] ; then
        ssh-keygen -q -N "" -t ed25519    -f "$1"/persist/etc/ssh/ssh_host_ed25519_key -C "@$setup_hostName"
    fi
    if [[ ! -e "$1"'/persist/etc/ssh/ssh_host_rsa_key' ]] ; then
        ssh-keygen -q -N "" -t rsa -b4096 -f "$1"/persist/etc/ssh/ssh_host_rsa_key -C "@$setup_hostName"
    fi
    if [[ ! -e "$1"'/persist/etc/ssh/initrd_host_rsa_key' ]] ; then
        ssh-keygen -q -N "" -t rsa -b4096 -f "$1"/persist/etc/ssh/initrd_host_rsa_key -C "@$setup_hostName"
    fi
)}

## Ensures a WireGuard key on the FS mounted at »$mountPath« and prints its public key.
#  $ nix-shell -p wireguard --run "/persist/etc/nixos/utils/functions.sh create-wireguard-key / wg0@$(hostname) | tee /persist/etc/nixos/pki/wg0@$(hostname).pub"
function create-wireguard-key {( set -eu # 1: mountPath, 2: keyName
    mkdir -p -- "$1"/persist/secret/
    if [[ !  -e "$1"/persist/secret/"$2" ]] ; then
        private="$(wg genkey)" ; public="$(wg pubkey <<<"$private")"
        write-secret "$1"/persist/secret/"$2" <<<"$private"
        printf %s "$public" >"$1"/persist/secret/"$2".pub
    fi
    cat "$1"/persist/secret/"$2".pub
)}

## Ensures an SSH key on the FS mounted at »$mountPath« and prints its public key.
function create-ssh-user-key {( set -eu # 1: mountPath, 2: --, 3: UID, 4: userName, 5: hostName
    mkdir -p -- "$1"/persist/etc/ssh/users/
    if [[ !  -e "$1"/persist/etc/ssh/users/"$4" ]] ; then
        ssh-keygen -q -N "" -t ed25519    -f "$1"/persist/etc/ssh/users/"$4" -C "$4@$5"
        chown "$3" "$1"/persist/etc/ssh/users/"$4"
    fi
    cat "$1"/persist/etc/ssh/users/"$4".pub
)}

## Uses the local key »$signingKey« to sign the host key »$hostKeyPath« for use as »${hostnames}.$domain« with »$expiration«.
function sign-ssh-key {( set -eu # 1: signingKey, 2: hostKeyPath, 3: principals, 4?: expiration
    signingKey=${1:?"Must be the path to the ».pub« of the SSH key used for signing, e.g.: /home/user/.ssh/gpg_rsa.pub"}
    hostKeyPath=${2:?"Must be the path to the public host key to sign, e.g.: /mnt/etc/ssh/ssh_host_ed25519_key.pub"}
     # principals: can also me a comma separated list of user names
    principals=${3:?"Must be comma separated list of (fully qualified) domain names or user names that this cert may be used for. If this contains a ».« (period), then the cert will be issued as host certificate."}
    expiration=${5:-+520w} # host key expiration time, which by default only makes clients warn
    if [[ $principals = *.* ]] ; then isHost=true ; fi

    # SSH_AUTH_SOCK="${SSH_AUTH_SOCK:-}"
    cmd=(
        ssh-keygen
        -I signed-key # signing mode, plus key identifier for logs
        -s "$signingKey" -U # use signing key from ssh-agent
        -${isHost:+h}n "$principals" #-h # create host cert (otherwise it's a client cert)
        -V "$expiration" "$hostKeyPath"
    ) ; "${cmd[@]}"

)}

## Same as »sign-ssh-key«, but pulls and pushes the host key from and to »$sshArgs.
#  $ ( host=some-test ; ./utils/functions.sh sign-ssh-key-remote root@$host /home/user/.ssh/gpg_rsa.pub /persist/etc/ssh/ssh_host_ed25519_key.pub ssh01.$host.niklasg.de )
function sign-ssh-key-remote {( set -eu # 1: sshArgs, ...: args of sign-ssh-key
    sshArgs=${1:?'Must be the SSH login arguments, e.g. »root@$ip«'}
    hostKeyPath=${3:?"Must be the path to the public host key to sign, e.g.: /mnt/etc/ssh/ssh_host_ed25519_key.pub"}
    shift ; args=("$@") # zero-indexed

    hostPub=$(ssh $sshArgs -- "cat '${hostKeyPath}'")
    workDir=$(mktemp -d "/tmp/known_hosts.XXXXXX") ; trap 'rm -rf ${workDir}' EXIT ; <<<$hostPub cat >"$workDir"/host.pub ; args[1]="$workDir"/host.pub # can't use pipes with ssh-keygen -.-

    sign-ssh-key "${args[@]}"

    cat "$workDir"/host-cert.pub | ssh $sshArgs /persist/etc/nixos/utils/functions.sh write-secret "${hostKeyPath/.pub/-cert.pub}" root:root 644 # (world readable)
)}


##
# Disk Formatting
##

# Notes segmentation and alignment:
# * Both fdisk and gdisk report start and end in 0-indexed sectors from the start of the block device.
# * (fdisk and gdisk have slightly different interfaces, but seem to otherwise be mostly equivalent, (fdisk used to not understand GPT).)
# * The MBR sits only in the first sector, a GPT additionally requires next 33 (34 total) and the (absolut) last 33 sectors. At least fdisk won't put partitions in the first 2048 sectors on MBRs.
# * Crappy flash storage (esp. micro SD cards) requires alignment to pretty big sectors for optimal (esp. write) performance. For reasons of inconvenience, vendors don't document the size of those. Not too extensive test with 4 (in 2022 considered to be among the more decent) micro SD cards indicates the magic number to be somewhere between 1 and 4MiB, but it may very well be higher for others.
#     * (source: https://lwn.net/Articles/428584/)
# * So alignment at the default »padSize=8MiB« actually seems a decent choice.

## Formats the given »$blockDev« with an MBR with four primary partitions: firmware + boot (»bootSize«), keystore (»ksSize«), swap (»swapSize«), and the remainder for the foot FS.
function format-mbr {( set -eu # 1: blockDev, 2?: padSize, 3?: bootSize, 4?: swapSize
    blockDev=$1
    :  ${padSize:=${2:-16384}}    #   8MiB / 512 # (e.g. for BIOS part)
    : ${bootSize:=${3:-4194304}}  #   2GiB / 512
    :   ${ksSize:=131072}         #  64MiB / 512
    : ${swapSize:=${4:-8388608}}  #   4GiB / 512

    # With the above values on a ~500GB SSD:
    # Device         Boot    Start       End   Sectors   Size Id Type
    # /dev/nvme0n1p1 *       16384   4210687   4194304     2G  b W95 FAT32
    # /dev/nvme0n1p2       4210688   4341759    131072    64M e8 unknown
    # /dev/nvme0n1p3       4341760  12730367   8388608     4G 82 Linux swap / Solaris
    # /dev/nvme0n1p4      12730368 976756782 964026415 459.7G bf Solaris

    printf "
        o                                # new MBR
        n;p;1                            # new ; primary ; part1
        $((padSize));$((padSize + bootSize - 1))   # start ; end
        t;b                              # type (; part1) ; W95 FAT32
        n;p;2                            # new ; primary ; part2
        $((padSize + bootSize));$((padSize + bootSize + ksSize - 1))  # start ; end
        t;2;e8                           # type ; part2 ; LUKS
        n;p;3                            # new ; primary ; part3
        $((padSize + bootSize + ksSize));$((padSize + bootSize + ksSize + swapSize - 1))  # start ; end
        t;3;82                           # type ; part3 ; Linux Swap
        n;p;4                            # new ; primary ; part4
        $((padSize + bootSize + ksSize + swapSize));-$((padSize + 1))  # start ; all (but leave some to spare, e.g. for GPT conversion)
        t;4;bf                           # type ; part4 ; Solaris (ZFS)
        a;1                              # active/boot ; part1 (u-boot/systemd-boot on part1 boots the kernel on part1)
        p;w                              # print ; write
    " | perl -pe 's/^ *| *#.*$//g' | perl -pe 's/; */\n/g' | fdisk "$blockDev" || true
    partprobe "$blockDev" ; sleep 1
)}

## Formats the given »$blockDev« with an GPT with four partitions: firmware + boot (»bootSize«), keystore (»ksSize«), swap (»swapSize«), and the remainder for the foot FS.
function format-gpt {( set -eu # 1: blockDev, 2?: padSize, 3?: bootSize, 4?: swapSize
    blockDev=$1
    :  ${padSize:=${2:-16384}}    #   8MiB / 512 # (e.g. for BIOS part)
    : ${bootSize:=${3:-4194304}}  #   2GiB / 512
    :   ${ksSize:=131072}         #  64MiB / 512
    : ${swapSize:=${4:-8388608}}  #   4GiB / 512

    # With the above values on a ~500GB SSD:
    # Number  Start (sector)    End (sector)  Size       Code  Name
    #    1           16384         4210687   2.0 GiB     ef00  EFI system partition
    #    2         4210688         4341759   64.0 MiB    8300  Linux LUKS
    #    3         4341760        12730367   4.0 GiB     8200  Linux swap
    #    4        12730368       976756749   459.7 GiB   BF00  Solaris root

    printf "
        o;y                              # new GPT ; confirm
        n;1                              # new ; primary ; part1
        $((padSize));$((padSize + bootSize - 1))  # start ; end
        ef00                             # type: EFI system partition
        n;2                              # new ; primary ; part2
        $((padSize + bootSize));$((padSize + bootSize + ksSize - 1))  # start ; end
        8309                             # type: Linux LUKS
        n;3                              # new ; primary ; part3
        $((padSize + bootSize + ksSize));$((padSize + bootSize + ksSize + swapSize - 1))  # start ; end
        8200                             # type: Linux swap
        n;4                              # new ; primary ; part4
        $((padSize + bootSize + ksSize + swapSize));-$((padSize + 1))  # start ; all
        BF00                             # type: Solaris root
        p;w;y                            # print ; write ; confirm
    " | perl -pe 's/^ *| *#.*$//g' | perl -pe 's/; */\n/g' | gdisk "$blockDev" || true # use »gdisk« for its similarity to »fdisk« (actually, »fdisk« also does GPT, but the part types are strange)
    partprobe "$blockDev" ; sleep 1
)}

## Creates LUKS device »$luksName« on »$rawDisk«, using key »$keystore/luks/$luksName/*.key«.
function format-luks {( set -eu # 1: rawDisk, 2: luksName
    keystore=/run/keystore-${setup_hostHash:0:8}/ ; rawDisk=$1 ; luksName=$2
    luksLabel=luks-"$luksName"-"${setup_hostHash:0:16}"
    primaryKey="$keystore"/luks/"$luksName"/0.key
    keyOptions='--pbkdf=pbkdf2 --pbkdf-force-iterations=1000'

    cryptsetup --batch-mode luksFormat --key-file="${primaryKey}" $keyOptions -c aes-xts-plain64 -s 512 -h sha256 --label="${luksLabel}" "$rawDisk"

    for index in 1 2 3 4 5 6 7 ; do
        if [[ -e "$keystore"/luks/"$luksName"/"$index".key ]] ; then
            cryptsetup luksAddKey --key-file="${primaryKey}" $keyOptions "$rawDisk" "$keystore"/luks/"$luksName"/"$index".key
        fi
    done

    cryptsetup --batch-mode luksOpen --key-file="${primaryKey}" "$rawDisk" "$luksName"-"${setup_hostHash:0:16}"
)}

## Creates LUKS mapping »$luksName« on »$rawDisk« if a key for »$luksName« is in the »$keystore«, otherwise uses it directly.
function format-luks-optional {( set -eu # 1: rawDisk, 2: luksName
    keystore=/run/keystore-${setup_hostHash:0:8}/ ; rawDisk=$1 ; luksName=$2
    if [[ -e "$keystore"/luks/"$luksName" ]] ; then
        format-luks "$rawDisk" "$luksName"
        printf %s /dev/mapper/"$luksName"-"${setup_hostHash:0:16}"
    else
        printf %s "$rawDisk"
    fi
)}

## Tries to open and mount the systems keystore from its LUKS partition. If successful, adds the traps to close it when the parent shell exits.
#  $ mount-keystore-luks
#  $ mount-keystore-luks --key-file=/dev/disk/by-partlabel/bootkey-${setup_hostHash:0:16}
#  $ read -s -p PIN: pin ; echo ' touch!' >&2 ; ykchalresp -2 "$pin" | mount-keystore-luks
#  Since bash puts each command in a pipeline in a subshell, pipe redirection can't be used, but this works:
#  $ mount-keystore-luks --key-file=<( printf %s "$setup_hostName" )
#  $ mount-keystore-luks --key-file=<( read -s -p PIN: pin ; echo ' touch!' >&2 ; ykchalresp -2 "$pin" )
#  And when operating on a different host's file system, e.g.:
#  $ zpool import -f -N -R /mnt/ rpool-${setup_hostHash:0:8} ; prepend_trap "zpool export rpool-${setup_hostHash:0:8}" EXIT
#  $ zfs load-key -r rpool-${setup_hostHash:0:8}
function mount-keystore-luks { # ...: cryptsetupOptions
    # (for the traps to work, this can't run in a sub shell, so also can't »set -eu«, so use »&&« after every command and in place of most »;«)
    short=${setup_hostHash:0:8} && long=${setup_hostHash:0:16} &&
    mkdir -p -- /run/keystore-$short &&
    cryptsetup open "$@" /dev/disk/by-label/luks-keystore-$long keystore-$short &&
    mount -o nodev,umask=0077,fmask=0077,dmask=0077,ro /dev/mapper/keystore-$short /run/keystore-$short &&
    prepend_trap "umount /run/keystore-$short ; rmdir /run/keystore-$short ; cryptsetup close keystore-$short" EXIT
}

## Given the keys in »$setup_cryptKeys«, populates the local array variable named »name_cryptProps« in the calling function with the crypt options for »datasetPath«.
function get-zfs-crypt-options { # 1: keystore, 2: datasetPath, 3: name_cryptProps, 4: name_cryptKey, 5: name_cryptRoot
    local keystore=$1 ; local name=$2 ; local -n __cryptProps=$3 ; local -n __cryptKey=$4 ; local -n __cryptRoot=$5
    if [[ $name =~ / ]] ; then local pool=${name/\/*/}/ ; local path=/${name/$pool/} ; else local pool=$name/ ; local path= ; fi
    local key=${pool/-[a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9][a-f0-9]'/'/}$path # strip hash from pool name
    __cryptProps=( ) ; __cryptKey='' ; __cryptRoot=''
    if [[ ${setup_cryptKeys[zfs/$key]:-} ]] ; then
        if [[ ${setup_cryptKeys[zfs/$key]} == unencrypted ]] ; then
            __cryptProps=( -o encryption=off ) # empty key to disable encryption
        else
            __cryptProps=( -o encryption=aes-256-gcm -o keyformat=hex -o keylocation=file://"$keystore"/zfs/"$key".key )
            __cryptKey=$keystore/zfs/$key.key ; __cryptRoot=$name
        fi
    else
        while true ; do
            key=$(dirname $key) ; name=$(dirname $name) ; if [[ $key == . ]] ; then break ; fi
            if [[ ${setup_cryptKeys[zfs/$key]:-} ]] ; then
                if [[ ${setup_cryptKeys[zfs/$key]} != unencrypted ]] ; then
                    __cryptKey=$keystore/zfs/$key.key ; __cryptRoot=$name
                fi ; break
            fi
        done
    fi
}

## Creates a ZFS pool.
function create-zpool {( set -eu # 1: mnt, 2: poolName, 3: properties, ...: deviceSpec
    keystore=/run/keystore-${setup_hostHash:0:8} ; mnt=$1 ; shift ; name=$1 ; shift ; properties=( $1 ) ; shift ; deviceSpec=( "$@" )

    # if a key is set / requested for the dataset, use it
    get-zfs-crypt-options "$keystore" "$name" cryptProps cryptKey cryptRoot
    # dataset options: »-o« --> »-O«
    for i in "${!cryptProps[@]}" ; do if [[ "${cryptProps[$i]}" == '-o' ]] ; then cryptProps[$i]='-O' ; fi ; done
    for i in "${!properties[@]}" ; do if [[ "${properties[$i]}" == '-o' ]] ; then properties[$i]='-O' ; fi ; done

    zpool create "${cryptProps[@]}" "${properties[@]}" -O normalization=formD -o ashift=${setup_my_setup_rpool_ashift:-12} -R "$mnt" "$name" "${deviceSpec[@]}" -f
)}

## Ensures that the system's datasets exist and have the defined properties (but not that they don't have properties tht aren't defined).
#  The pool(s) must exist, be imported with root prefix »$mnt«, and (if datasets are to be created or encryption roots to be inherited) the system's keystore must be open (see »mount-keystore-luks«).
#  »keystatus« and »mounted« of existing datasets should remain unchained, newly crated datasets will not be mounted but have their keys loaded.
#  The function's output can be passed to »unlock-datasets« to load the keys for any datasets that have »canmount != off« and an absolute »mountpoint« (i.e. can be mounted without further information).
#  $ mkdir -p /mnt/ ; ensure-datasets /mnt/ | unlock-datasets /mnt/ && mount-system /mnt/ $setup_currentSystem/etc/fstab
#  $ for dir in dev/ sys/ ; do mount tmpfs -t tmpfs /mnt/$dir ; done ; prepend_trap 'for dir in dev/ sys/ ; do umount /mnt/$dir ; done' EXIT
#  $ mount /dev/disk/by-label/bt-${setup_hostHash:0:8} /mnt/boot/ ; prepend_trap 'umount /mnt/boot/' EXIT
#  $ TMPDIR=/tmp nixos-install --system $setup_currentSystem --no-root-passwd --root /mnt/
function ensure-datasets {( set -eu # 1: mnt, 2?: filterExp
    mnt=$1 ; while [[ "$mnt" == */ ]] ; do mnt=${mnt:0:(-1)} ; done # (remove any tailing slashes)
    filterExp=${2:-'^'}
    keystore=/run/keystore-${setup_hostHash:0:8}
    tmpMnt=$(mktemp -d) ; trap "rmdir $tmpMnt" EXIT

    IFS=$'\n' names=($(LC_ALL=C sort <<<"${!setup_datasets[@]}")) ; unset IFS ; mounts=''
    for dataset in "${names[@]}" ; do
        if  [[ ! $dataset =~ $filterExp ]] ; then printf 'Skipping dataset »%s« since it does not match »%s«\n' "$dataset" "$filterExp" >&2 ; continue ; fi
        props="${setup_datasets["$dataset"]}"

        get-zfs-crypt-options "$keystore" "$dataset" cryptProps cryptKey cryptRoot # if a key is set / requested for the dataset, use it

        permissions=$(<<<"$props" grep -o -P ' -o permissions=\K\S+' || true) ; if [[ "$permissions" ]] ; then props="${props/" -o permissions=$permissions "/' '}" ; fi
        allow=$(<<<"$props" grep -o -P ' -o allow=\K\S+' || true) ; if [[ "$allow" ]] ; then props="${props/" -o allow=$allow "/' '}" ; fi

        mountpoint=$(<<<"$props" grep -o -P 'mountpoint=\K\S+' || true)
        if [[ "$mountpoint" == /* && ! "$props" =~ " canmount=off " ]] ; then mounts+="$dataset"' '"$mountpoint"' '"$cryptRoot"' '"$cryptKey"$'\n' ; fi
        ephemeralKey='' ; if [[ $props =~ " -o keyformat=ephemeral " ]] ; then ephemeralKey=true ; cryptRoot=$dataset ; props="${props/' -o keyformat=ephemeral '/' -o keylocation=file:///dev/null '}" ; fi

        if zfs get -o value -H name "$dataset" &>/dev/null ; then # dataset exists
            if [[ "$mountpoint" ]] ; then # don't set the current mount point again (no-op), cuz that fails if the dataset is mounted
                current=$(zfs get -o value -H mountpoint "$dataset")
                current=${current/$mnt/}
                if [[ "$mountpoint" == "${current:-/}" ]] ; then
                    props="${props/" -o mountpoint=$mountpoint "/' '}"
                fi
            fi
            names=$(<<<"$props"  grep -o -P ' -o \K[^=]+') ; values=$(<<<"$props"  grep -o -P ' -o \S+=\K\S+')
            if [[ $values != "$(zfs get -o value -H "${names//$'\n'/','}" "$dataset")" ]] ; then
                ( set -x ; zfs set ${props//' -o '/' '} "$dataset" )
            fi
            if [[ $cryptRoot && $(zfs get -o value -H encryptionroot "$dataset") != "$cryptRoot" ]] ; then ( # inherit key from parent
                parent=$(dirname "$dataset")
                if [[ $(zfs get -o value -H keystatus "$parent") != available ]] ; then
                    zfs load-key -L file://"$cryptKey" "$parent" ; trap "zfs unload-key $parent || true" EXIT
                fi
                if [[ $(zfs get -o value -H keystatus "$dataset") != available ]] ; then
                    zfs load-key -L file://"$cryptKey" "$dataset" # will unload with parent
                fi
                ( set -x ; zfs change-key -i "$dataset" )
            ) ; fi
        else # create dataset
            keylocation=$(<<<"$props" grep -o -P ' -o keylocation=\K\S+' || true) ; if [[ "$keylocation" ]] ; then props="${props/" -o keylocation=$keylocation "/' '}" ; fi # remove overwritten keylocation for now
            # TODO: if [[ $cryptRoot && $(zfs get -o value -H keystatus "$cryptRoot") != available ]] ; then ... load key while in this block ...
            if [[ ! $ephemeralKey ]] ; then
                ( set -x ; zfs create $props "${cryptProps[@]}" "$dataset" )
            else
                </dev/urandom tr -dc 0-9a-f | head -c 64 | ( set -x ; zfs create $props -o encryption=aes-256-gcm -o keyformat=hex -o keylocation=file:///dev/stdin "$dataset" )
                zfs unload-key "$dataset"
            fi
            if [[ "$permissions" ]] ; then (
                owner=$(<<<"$permissions" cut -d= -f1) ; access=$(<<<"$permissions" cut -d= -f2)
                mount -t zfs -o zfsutil "$dataset" $tmpMnt ; trap "umount '$dataset'" EXIT
                ( set -x ; chpem "$access" "$owner" "$tmpMnt" )
            ) ; fi
            if [[ "$keylocation" ]] ; then
                ( set -x ; zfs set keylocation=$keylocation "$dataset" )
            fi
            ( set -x ; zfs snapshot -r "$dataset"@empty )
        fi
        for args in ${allow//;/ } ; do
            # »zfs allow $dataset« seems to be the only way to view permissions, and that is not very parsable -.-
            ( set -x ; zfs allow ${args//:/ } "$dataset" >&2 )
        done
    done

    cat <<<"$mounts"
)}

## Loads the keys for the datasets output by »ensure-datasets« at prefix »$mnt«.
function unlock-datasets {( set -eu # 1: mnt
    mnt=$1 ; LC_ALL=C sort -k2 | while read dataset mountpoint cryptRoot cryptKey ; do
        if [[ $dataset ]] ; then if ! mountpoint -q "$mnt"/"$mountpoint" ; then
            if [[ $cryptRoot && $(zfs get -o value -H keystatus "$cryptRoot") != available ]] ; then
                zfs load-key -L file://"$cryptKey" "$cryptRoot"
            fi
        fi ; fi
    done
)}

## Mounts the datasets output by »ensure-datasets« at prefix »$mnt«.
#  »mount-system« below is generally the preferred method, but that does only mount datasets that are specified to be mounted at boot.
function mount-datasets {( set -eu # 1: mnt
    mnt=$1 ; LC_ALL=C sort -k2 | while read dataset mountpoint cryptRoot cryptKey ; do
        if [[ $dataset ]] ; then if ! mountpoint -q "$mnt"/"$mountpoint" ; then
            mkmnt "$mnt"/"$mountpoint"
            mount -t zfs -o zfsutil "$dataset" "$mnt"/"$mountpoint"
        fi ; fi
    done
)}

## Mounts all file systems as it would happen during boot, but at path prefix »$mnt«.
function mount-system {( set -eu # 1: mnt, 2?: fstabPath
    # mount --all --fstab $setup_currentSystem/etc/fstab --target-prefix "$1" -o X-mount.mkdir # (»--target-prefix« is not supported on Ubuntu 20.04)
    mnt=$1 ; fstabPath=${2:-"$setup_currentSystem/etc/fstab"}
    <$fstabPath grep -v '^#' | LC_ALL=C sort -k2 | while read source target type options numbers ; do
        if [[ ! $target || $target == none ]] ; then continue ; fi
        options=,$options, ; options=${options//,ro,/,}
        if [[ $options =~ ,r?bind, ]] ; then continue ; fi # TODO: also rbind?
        if ! mountpoint -q "$mnt"/"$target" ; then
            mkmnt "$mnt"/"$target"
            mount -t $type -o "${options:1:(-1)}" "$source" "$mnt"/"$target"
        fi
    done
    # Since bind mounts may depend on other mounts not only for the target (which the sort takes care of) but also for the source, do all bind mounts last. This would break if there was a different bind mountpoint within a bind-mounted target.
    <$fstabPath grep -v '^#' | LC_ALL=C sort -k2 | while read source target type options numbers ; do
        if [[ ! $target || $target == none ]] ; then continue ; fi
        options=,$options, ; options=${options//,ro,/,}
        if [[ ! $options =~ ,r?bind, ]] ; then continue ; fi # TODO: also rbind?
        if ! mountpoint -q "$mnt"/"$target" ; then
            mkmnt "$mnt"/"$target"
            source=$mnt/$source ; if [[ ! -e $source ]] ; then mkdir -p "$source" ; fi
            mount -t $type -o "${options:1:(-1)}" "$source" "$mnt"/"$target"
        fi
    done
)}

## Unmounts all file systems (that would be mounted during boot / by »mount-system«).
function unmount-system {( set -eu # 1: mnt, 2?: fstabPath
    mnt=$1 ; fstabPath=${2:-"$setup_currentSystem/etc/fstab"}
    <$fstabPath grep -v '^#' | LC_ALL=C sort -k2 -r | while read source target rest ; do
        if [[ ! $target || $target == none ]] ; then continue ; fi
        if mountpoint -q "$mnt"/"$target" ; then
            umount "$mnt"/"$target"
        fi
    done
)}

## With all of the active system's devices/pools/filesystems closed/exported/unmounted (e.g. just after connecting the disk) opens/imports/mounts them all, leaving »trap«s in the current current shell to close it all on »EXIT«.
#  Perfect to update a system's installation afterwards:
#  $ TMPDIR=/tmp nixos-install --system $setup_currentSystem --no-root-passwd --root /tmp/nixos-install-${setup_hostName}
function open-system { # (for the traps to work, this can't run in a sub shell, so also can't »set -eu«, so use »&&« after every command and in place of most »;«)

    if ! mount-keystore-luks --key-file=<(printf %s "$setup_hostName") ; then
        if ! mount-keystore-luks --key-file=/dev/disk/by-partlabel/bootkey-${setup_hostHash:0:16} ; then
            if ! mount-keystore-luks --key-file=<( read -s -p PIN: pin && echo ' touch!' >&2 && ykchalresp -2 "$pin" ) ; then
                # TODO: try static yubikey challenge
                mount-keystore-luks &&
            :;fi &&
        :;fi &&
    :;fi &&

    mnt=/tmp/nixos-install-${setup_hostName} && mkdir -p -- $mnt && prepend_trap "rmdir $mnt" EXIT &&

    if [[ $setup_my_boot_zfs_enable ]] ; then
        zpool import -d /dev/ -f -N -R $mnt rpool-${setup_hostHash:0:8} && prepend_trap "zpool export rpool-${setup_hostHash:0:8}" EXIT &&
        zfs load-key -r rpool-${setup_hostHash:0:8} && # (export also unloads keys)
        ensure-datasets $mnt | unlock-datasets $mnt &&
    :;fi &&

    mount-system $mnt $setup_currentSystem/etc/fstab && prepend_trap "unmount-system $mnt $setup_currentSystem/etc/fstab" EXIT &&

    for dir in dev/ sys/ ; do mkdir -p $mnt/$dir ; mount tmpfs -t tmpfs $mnt/$dir ; done && prepend_trap 'for dir in dev/ sys/ ; do umount -l $mnt/$dir ; done' EXIT &&
    true # (success)
}

## Migrates the current system (which may be the booted host on which this function is called) to a different disk.
#  TODO: Test this for at least one live and one other system!
function transplant-system {( set -eu # 1: blockDev
    blockDev=$1
    trap - EXIT # reset »prepend_trap« stack
    life='' ; if [[ $setup_hostName == "$(hostname)" ]] ; then live=true ; fi
    if [[ ! $setup_my_boot_zfs_enable ]] ; then echo "(For now) this only works for ZFS as root FS!" ; exit 1 ; fi

    rpool=rpool-${setup_hostHash:0:8}
    keystore=/run/keystore-${setup_hostHash:0:8}/
    (
        padSize=216384 ; bootSize=$setup_my_setup_boot_size ; ksSize=131072 ; swapSize=$setup_my_setup_swap_size
        function partSize { printf %s "$(( $(blockdev --getsize64 "$1") / 512 ))" ; }
        diskSize=$(partSize $blockDev)
        oldRpoolSize=$(partSize /dev/disk/by-label/$rpool)
        newRpoolSize=$(( diskSize - padSize - bootSize - ksSize - swapSize ))
        if (( newRpoolSize < oldRpoolSize )) ; then echo "$blockDev is too small to fit $rpool. Reduce the BOOT or SWAP size, or choose a larger disk!" ; exit 1 ; fi
    )

    oldMnt=$(mktemp -d) ; prepend_trap "if mountpoint -q $oldMnt ; then umount $oldMnt l fi ; rmdir $oldMnt" EXIT
    newMnt=$(mktemp -d) ; prepend_trap "if mountpoint -q $newMnt ; then umount $newMnt l fi ; rmdir $newMnt" EXIT

    # there necessarily will be duplicate disk labels
    oldPrefix=$(realpath /dev/disk/by-label/$rpool) ; oldPrefix=${oldPrefix::(-1)}
    newPrefix=$(realpath $newPrefix) ; if [[ $newPrefix != /dev/sd* ]] ; then newPrefix=${newPrefix}p ; fi

    # same formatting as in ./install.sh.md
    if [[ "$setup_hardware" == rpi ]] ; then
        format-mbr "$blockDev" '' "$setup_my_setup_boot_size" "$setup_my_setup_swap_size"
    else
        format-gpt "$blockDev" '' "$setup_my_setup_boot_size" "$setup_my_setup_swap_size"
        if [[ "$setup_hardware" == hetzner ]] ; then add-bios-partition "$blockDev" ; fi
    fi

    # copy (& remount) boot
    format-boot-fat ${newPrefix}1 ; mount ${newPrefix}1 $newMnt
    if [[ $live ]] ; then mount -o remount,ro ${oldPrefix}1 ; else mount ${oldPrefix}1 $oldMnt ; fi
    rsync -a $oldMnt/ $newMnt/
    umount $newMnt ; umount ${oldPrefix}1 ; if [[ $live ]] ; then mount ${newPrefix}1 /boot/ ; fi

    # copy keystore (always closed)
    <${oldPrefix}2 pv >${newPrefix}2

    # recreate (and switch) swap
    swapPart=/dev/disk/by-label/swap-${setup_hostHash:0:10}
    if [[ $live ]] ; then swapoff $swapPart ; fi
    if [[ $live && -e "$keystore"/luks/swap ]] ; then cryptsetup close swap-"${setup_hostHash:0:16}" ; fi
    format-swap-part ${newPrefix}3
    if [[ $live ]] ; then if [[ "$keystore"/luks/swap ]] ; then swapon /dev/mapper/swap-"${setup_hostHash:0:16}" ; else swapon ${newPrefix}3 ; fi ; fi

    # clone rpool
    # (luks encrypted rpool (currently) not supported here)
    if [[ ! $live ]] ; then zpool import $rpool ; fi
    zpool attach -s -w $rpool ${oldPrefix}4 ${newPrefix}4 # Sequential (i.e. fast) and Wait for completion
    zpool attach -s -w $rpool ${oldPrefix}4
    if [[ ! $live ]] ; then zpool export $rpool ; fi

)}

## Creates a fat32 »/boot« partition with a label derived from »'boot'« and the »$hostName«.
function format-boot-fat {( set -eu # 1: partition
    partition=$1
    btLabel=bt-${setup_hostHash:0:8}
    mkfs.fat -F 32 -n "$btLabel" "$partition" ; partprobe "$partition" ; sleep 1
)}

## Creates an optionally encrypted swap partition with a label derived from »'swap'« and the »$hostName«.
function format-swap-part {( set -eu # 1: partition
    partition=$1
    partition=$(format-luks-optional "$partition" swap)
    swapLabel=swap-${setup_hostHash:0:10}
    mkswap -L "$swapLabel" "$partition"
)}

## Creates a LUKS/fat keystore to be unlocked and used during boot, and fills it with the keys from »$keystore«.
function format-keystore-luks {( set -eu # 1: partition
    keystore= ; partition=$1
    format-luks "$partition" keystore
    ksLabel=ks-${setup_hostHash:0:8} ; keystorePath=/dev/mapper/keystore-${setup_hostHash:0:16}
    mkfs.fat -n "$ksLabel" "$keystorePath"
    tmp=$(mktemp -d) ; mount "$keystorePath" $tmp ; trap "umount $tmp" EXIT
    rsync -a /run/keystore-${setup_hostHash:0:8}/ $tmp/
)}

## Creates an EXT4 main partition for minimalist installations.
function format-root-ext4 {( set -eu # 1: partition
    partition=$1
    rootLabel=root-${setup_hostHash:0:8}
    mkfs.ext4 -F -E nodiscard -L "$rootLabel" "$partition" ; partprobe "$partition" ; sleep 1
)}

## Adds a BIOS boot loader partition to an existing GPT disk.
function add-bios-partition {( set -eu # 1: blockDev
    sgdisk --new=14:2048:+2048 --change-name=14:bios-${setup_hostHash:0:16} --typecode=14:EF02 "$1" # ( /dev/sdx14  2048  4095  2048  1M BIOS boot )
    partprobe "$1" ; sleep 1
)}


## On the host and for the user it is called by, creates/registers a VirtualBox VM meant to run the shells target host. Requires the path to the target host's »diskImage« as the result of running the install script. The image file may not be deleted or moved. If »bridgeTo« is set (to a host interface name, e.g. as »eth0«), it is added as bridged network "Adapter 2" (which some hosts need).
function register-vbox {( set -eu # 1: diskImage, 2?: bridgeTo
    diskImage=$1 ; bridgeTo=${2:-}
    vmName="nixos-$setup_hostName"

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

