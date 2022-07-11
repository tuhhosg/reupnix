#!@shell@
set -eu ; function main {

# TODO:
# * validate that "existing store artifacts" actually exist

generic-arg-parse "$@"
# --dir=DIR        The temporary dir to extract to. Must be on the same FS as /nix/store/.
# --only-recv      Quit after reading the files from stdin and extracting them to --dir.
# --no-recv        Do not read anything from stdin, expect files to already exist in --dir.
# --restore        Restore /nix/store/.links to contain all files in the target closure.
# --no-links       Pretend /nix/store/.links doesn't exist.
# --dry-run        Don't actually perform any action that would write outside of --dir. Fails if targets aren't already in /nix/store/.
# --verbose
# --status
# --no-delete
# --only-delete

# As root, give this script write access to a read-only /nix/store/:
if [[ $(id -u) == 0 ]] && ( ! touch /nix/store/.rw-test &>/dev/null || ! rm /nix/store/.rw-test &>/dev/null ) ; then
    if [[ ! ${args[no-unshare]:-} ]] ; then exec @unshare@ --fork --mount --uts --mount-proc --pid -- "$0" --no-unshare "$@" ; fi
    if [[ ! ${args[no-remount]:-} ]] ; then mount --make-rprivate / ; mount --bind /nix/store /nix/store ; mount -o remount,rw /nix/store ; fi
fi

dir=${args[dir]:-/nix/store/.receive} ; mkdir -p "$dir" ; cd "$dir"
toplevel='unknown paths' ; check-toplevel () { if [[ -e "$dir"/.toplevel-paths ]] ; then toplevel=$(cat "$dir"/.toplevel-paths) ; fi ; } ; check-toplevel
links=$dir/.links ; if [[ ${args[restore]:-} || ( ! ${args[no-links]:-} && -e /nix/store/.links ) ]] ; then links=/nix/store/.links ; fi
v1=: ; if [[ ${args[verbose]:-} ]] ; then v1='set -x' ; fi
run=( ) ; if [[ ${args[dry-run]:-} ]] ; then if [[ ${args[verbose]:-} ]] ; then run=( : ) ; else run=( echo -E '> ' ) ; fi ; fi
status () { : ; } ; if [[ ${args[status]:-} ]] ; then status () { echo "Completed stage: $1" ; } ; fi
if [[ ${args[status]:-} ]] ; then trap 'if [[ $? != 0 ]] ; then status="failed ($?)" ; else status=succeeded ; fi ; check-toplevel ; echo "Uploading $toplevel $status"' EXIT ; fi

if [[ ! ${args[only-delete]:-} ]] ; then # this closes where the »no-delete« if begins


# Get all the new files, plus the meta files:
if [[ ! ${args[no-recv]:-} ]] ; then while read -r name flags size ; do
    if [[ $name == '.' || $name == '..' || $name == */* ]] ; then echo "Receiving invalid file name $name, aborting" ; exit 1 ; fi
    if [[ $flags == l ]] ; then
        ( $v1 ; ln -sfT "$(head -c $size)" "$name" )
        touch -t 197001010100.01 --no-dereference "$name"
    else
        touch -t 197001010100.01 "$name" ; chmod 660 "$name"
        ( $v1 ; head -c $size >"$name" )
        if [[ $flags == *x* ]] ; then ( $v1 ; chmod 555 "$name" ) ; else ( $v1 ; chmod 444 "$name" ) ; fi
    fi
    read -r -d '' -n 1 # (consume the tailing newline)
done ; fi
check-toplevel
status 'received new files'
if [[ ${args[only-recv]:-} ]] ; then exit 0 ; fi


# Ensure all the required files that already existed are in $dir or $links:
if [[ ${args[no-links]:-} || ! -e /nix/store/.links ]] ; then (
    mkdir -p "$links" ; cd "$links"
    while IFS== read -r -d $'\0' hash path ; do
        # $links never gets written to (thus can't contain partial files) and $dir gets cleared on error, so anything in $links should be good:
        [[ -e ./$hash ]] || ( $v1 ; ln -T /nix/store/"$path" ./$hash )
    done <"$dir"/.restore-links
) ; fi
status 'prepared existing files'


# Create new store paths:
( cd /nix/store/ ; $v1 ; while IFS=/ read -r -d $'\0' type hash mode name ; do
    case "$type" in
        r) cd /nix/store/ ;;
        d) name=$hash ; if [[ ! -d "$name" ]] ; then "${run[@]}" mkdir "$name" ; fi ; cd "$name" ;; # (due to the parsing, $name can't contain any /, and mkdir errors if $name exists)
        p) cd .. ; if [[ $PWD == /nix/ ]] ; then echo "create-paths script stepped out of /nix/store/" ; exit 2 ; fi ;;
        f) if [[ ! -f "$name" && ! -L "$name" ]] ; then
            if [[ -f "$links"/"$hash" || -L "$links"/"$hash" ]] ; then "${run[@]}" ln -T "$links"/"$hash" "$name" ; else "${run[@]}" ln -T "$dir"/"$hash" "$name" ; fi
        fi ;;
        *) echo "Invalid create-paths instruction: $type" ; exit 1 ;;
    esac
done ) <./.cerate-paths
status 'created new store paths'


# Save the new links:
if [[ ! ${args[no-links]:-} && -e /nix/store/.links ]] ; then
    [[ ! ${args[verbose]:-} ]] || echo '+ mv -t /nix/store/.links/' *
    [[   ${args[dry-run]:-} ]] || printf '%s\0' * | @xargs@ -r0 -- mv -t /nix/store/.links/
    [[ ! ${args[dry-run]:-} ]] || printf '%s\0' * | @xargs@ -r0 -- rm
else
    printf '%s\0' * | @xargs@ -r0 -- rm
fi
status 'saved new links'


fi ; if [[ ${args[no-delete]:-} ]] ; then exit 0 ; fi


# Remove old store paths:
while IFS= read -r path; do
    ( $v1 ; "${run[@]}" rm -rf /nix/store/"$path" )
done <./.delete-paths
status 'removed old store paths'


# Leave the links dir in a clean state:
if [[ ! ${args[no-links]:-} && -e /nix/store/.links ]] ; then
    while IFS= read -r hash; do
        ( $v1 ; "${run[@]}" unlink /nix/store/.links/$hash )
    done <./.prune-links
fi
status 'pruned old links'


# Cleanup:
rm -rf .links
rm .toplevel-paths .restore-links .cerate-paths .delete-paths .prune-links
rmdir "$dir" # should be empty at this point
status 'completed cleanup'

}
@genericArgParse@

main "$@"
