#!@shell@ -eu

# TODO:
# * before applying, should validate that "existing store artifacts" actually exist

description="Receives a stream of Nix store components created by »nix-store-send«, and unpacks and saves them to the »/nix/store«.
When creating the stream, a set of »before« and »after« Nix store components were supplied (see »nix-store-send« for more detail).
The stream should then be received on a host where the »before« components are present. Applying makes the »after« components available (instead, unless delete+prune are skipped).

More precisely, if either the dependency closure of the set of »before« or »after« components is present on a host before receiving a stream, then applying it completely (by running all phases of »nix-store-recv«) ensures that afterwards the dependency closure of the »after« components is present, and anything in »closure(before) - closure(after)« is deleted. The operation (as a whole) is thus idempotent.
"
declare -g -A allowedArgs=(
               [--dir=DIR]="The temporary dir to extract to. Must be on the same filesystem as »/nix/store/«. Defaults to »/nix/store/.receive«."
        [--skip-completed]="If there is a receive in progress (i.e. »--dir« exists), skip any phases that were completed already."
      [--force-read-input]="If a previous »read-input« phase was started but did not complete, restart it with the stream on stdin."
         [--force-cleanup]="If there is a receive in progress, perform the »cleanup« phase even if not all previous phases completed yet."
         [--links-dir=DIR]="The directory where to expect (and maintain) or restore hardlinks to existing files. Defaults to »/nix/store/.links« if that exists, »--dir/.links« otherwise."
        [--maintain-links]="Move links to newly created files to »--links-dir« and remove outdated links from it, even if that is not »/nix/store/.links«."

               [--dry-run]="Don't actually perform any action that would write outside of »--dir«. The »install« phase fails if targets aren't already in /nix/store/."
               [--verbose]="Log out significant commands before running them."
                [--status]="Show status messages (when phases complete)."
            [--no-remount]="Do not remount the »/nix/store« as writable for this process (requires it to be writable already)."
)
details="
»nix-store-recv« works in the following phases:
* read-input:     Receive instructions and new files from stdin, and store then in »--dir«
* restore-links:  Restore hardlinks to files in »existing« (which are also in »after«) to »--links-dir«
* install:        Create new components in the Nix store by hardlinking to the files in »--links-dir« and »--dir«
* save-links:     Hardlink-copy all files from »--dir« to »--link-dir«
* delete:         Delete all old components in »closure(before) - closure(after)« from the Nix store
* prune-links:    Delete any hardlinks to files that were needed »before«, but not »after, from »--links-dir«
* cleanup:        Remove instructions and temporary hardlinks (i.e. delete »--dir«)
Usually, depending on whether »/nix/store/.links« exists, only either »restore-links« or »save-links«/»prune-links« will actually do anything.
»read-input« by default aborts if »--dir« exists, and is the only phase that writes files. All other phases only create hardlinks to existing files.
Since the hardlinks are only created if their new names don't yet exist, and and only deleted if they do exists, all the other stages are no-ops if they were executed before, even partially.

Each phase may be skipped by passing »--no-<phase>«, or run exclusively by passing »--only-<phase>«. This can be used for example to separate the actual stream receiving of the »read-input« phase from applying the stream, or to run tests in between »install« and »delete«.
The whole process should be idempotent, and each individual phase is idempotent if »--skip-completed« is passed, and all of and only its predecessors were executed.

Since »nix-store-recv« has no way to check whether a store component is complete (in regards to its own files or its dependencies, i.e. that it is 'valid' in Nix terms), ensuring that either »before« or »after« (including their dependencies) exist, before running »nix-store-recv« on a stream, is left to the caller.
"

for stage in read-input restore-links install save-links delete prune-links cleanup ; do
    allowedArgs[--no-$stage]="Do not run stage »$stage«."
    allowedArgs[--only-$stage]="Do only run stage »$stage«."
done

function main {
    generic-arg-parse "$@"
    generic-arg-help "$0" '' "$description" "$details"

    # As root, give this script write access to a read-only /nix/store/:
    if [[ $(id -u) == 0 ]] && ( ! touch /nix/store/.rw-test &>/dev/null || ! rm /nix/store/.rw-test &>/dev/null ) ; then
        if [[ ! ${args[no-remount]:-} ]] ; then
            if [[ ! ${args[internal-no-unshare]:-} ]] ; then exec @unshare@ --fork --mount --uts --mount-proc --pid -- "$0" --internal-no-unshare "$@" ; fi
            mount --make-rprivate / ; mount --bind /nix/store /nix/store ; mount -o remount,rw /nix/store
        fi
    fi
    unset args[internal-no-unshare]
    generic-arg-verify 3

    dir=${args[dir]:-/nix/store/.receive}
    links=$dir/.links ; if [[ -e /nix/store/.links ]] ; then links=/nix/store/.links ; fi ; if [[ ${args[links-dir]:-} ]] ; then links=${args[links-dir]} ; fi

    v1=: ; if [[ ${args[verbose]:-} ]] ; then v1='set -x' ; fi
    run=( ) ; if [[ ${args[dry-run]:-} ]] ; then if [[ ${args[verbose]:-} ]] ; then run=( : ) ; else run=( echo -E '> ' ) ; fi ; fi

    status () { : ; } ; if [[ ${args[status]:-} ]] ; then status () { echo "Completed stage: $1" ; } ; fi
    get-toplevel () { if [[ -e "$dir"/.toplevel-paths ]] ; then cat "$dir"/.toplevel-paths ; elif [[ ${toplevelPaths:-} ]] ; then echo "$toplevelPaths" ; else echo 'unknown paths' ; fi ; }
    if [[ ${args[status]:-} ]] ; then trap '( ok=$? ; if [[ $ok != 0 ]] ; then status="failed ($ok)" ; else status=succeeded ; fi ; echo "Uploading $(get-toplevel) $status" )' EXIT ; fi

    only= ; if [[ ' '${!args[@]} == *' only-'* ]] ; then only=1 ; fi # (this should ignore flags whose value is '')

    for stage in read-input restore-links install save-links delete prune-links cleanup ; do
        if [[ ! $only || ${args[only-$stage]:-} ]] && [[ ! ${args[no-$stage]:-} ]] ; then do-$stage ; fi
    done

}


# Receive instructions and new files:
function do-read-input {
    if [[ ${args[force-read-input]:-} ]] ; then rm -rf "$dir" ; fi
    if [[ -e $dir/.data-end && ${args[skip-completed]:-} ]] ; then return 0 ; fi
    if [[ -e $dir ]] ; then echo "File receive dir $dir already exists. This indicates that there is an incomplete update in progress or aborted. Wait for the update to complete, pass --skip-completed or --force-read-input, or manually remove $dir" ; exit 1 ; fi
    mkdir -p "$dir" ; cd "$dir"
    local meta=1
    while read -r name flags size ; do
        if [[ $name == '.' || $name == '..' || $name == */* ]] ; then echo "Receiving invalid file name $name, aborting" ; exit 2 ; fi
        if [[ $meta ]] ; then
            if [[ $name != .* ]] || [[ $flags != - ]] ; then echo "Invalid stream header" ; exit 2 ; fi
            if [[ $name == .meta-end ]] ; then
                if ! [[ -e .toplevel-paths && -e .restore-links && -e .cerate-paths && -e .delete-paths && -e .prune-links ]] ; then echo "Incomplete stream header" ; exit 2 ; fi
                meta=''
            fi
        else
            if [[ $name == '.'* ]] ; then
                if [[ $name == .data-end ]] ; then
                    touch -t 197001010100.01 .data-end ; break
                else
                    echo "Receiving invalid file name $name, aborting" ; exit 2
                fi
            fi
        fi
        if [[ $flags == l ]] ; then
            ( $v1 ; ln -sfT "$(head -c $size)" "$name" )
            touch -t 197001010100.01 --no-dereference "$name"
        else
            touch -t 197001010100.01 "$name" ; chmod 660 "$name"
            ( $v1 ; head -c $size >"$name" )
            if [[ $flags == *x* ]] ; then ( $v1 ; chmod 555 "$name" ) ; else ( $v1 ; chmod 444 "$name" ) ; fi
        fi
        read -r -d '' -n 1 # (consume the tailing newline)
    done
    if [[ ! -e .data-end ]] ; then echo "Stream ended before receiving the end marker, aborting" ; exit 2 ; fi
    status 'received instructions and new files'
}


# Restore hardlinks to existing files:
function do-restore-links {
    # TODO: this is idempotent across »cleanup« only if »$links« persists (otherwise, if »do-delete« was executes, the files that ».restore-links« references to don't exist anymore. Though in that case, »do-install« also must have completed, which means the links aren't needed anyway.)
    if [[ -e $dir/.data-end && ${args[skip-completed]:-} && ! -e $dir/.restore-links ]] ; then return 0 ; fi
    if [[ ! -e $dir/.restore-links ]] ; then echo "Can't restore links, meta file is missing" ; exit 1 ; fi
    mkdir -p "$links" ; cd "$links"
    while IFS== read -r -d $'\0' hash path ; do
        # $links never gets written to (thus can't contain partial files) and $dir gets cleared on error, so anything in $links should be good:
        [[ -f ./$hash || -L ./$hash ]] || ( $v1 ; ln -T /nix/store/"$path" ./$hash )
    done <"$dir"/.restore-links
    rm "$dir"/.restore-links
    status 'restored hardlinks to existing files'
}


# Install new components to the store:
function do-install {
    if [[ -e $dir/.data-end && ${args[skip-completed]:-} && ! -e $dir/.cerate-paths ]] ; then return 0 ; fi
    if [[ ! -e $dir/.data-end ]] ; then echo "Won't install store components, update stream was not received completely" ; exit 1 ; fi
    if [[ ! -e $dir/.cerate-paths ]] ; then echo "Can't install store components, meta file is missing" ; exit 1 ; fi
    cd /nix/store/
    ( $v1 ; while IFS=/ read -r -d $'\0' type hash mode name ; do case "$type" in
        r) cd /nix/store/ ;;
        d) name=$hash ; if [[ ! -d "$name" ]] ; then "${run[@]}" mkdir "$name" ; fi ; cd "$name" ;; # (due to the parsing, $name can't contain any /, and mkdir errors if $name exists)
        p) cd .. ; if [[ $PWD == /nix/ ]] ; then echo "create-paths script stepped out of /nix/store/" ; exit 2 ; fi ;;
        f) if [[ ! -f "$name" && ! -L "$name" ]] ; then
            if [[ -f "$links"/"$hash" || -L "$links"/"$hash" ]] ; then "${run[@]}" ln -T "$links"/"$hash" "$name" ; else "${run[@]}" ln -T "$dir"/"$hash" "$name" ; fi
        fi ;;
        *) echo "Invalid create-paths instruction: $type" ; exit 1 ;;
    esac ; done ) <"$dir"/.cerate-paths
    rm "$dir"/.cerate-paths
    status 'installed new components to the store'
}


# Save hardlinks to new files:
function do-save-links {
    cd "$dir"
    if [[ ! ${args[maintain-links]:-} && $links != /nix/store/.links ]] ; then return 0 ; fi
    [[ ! ${args[verbose]:-} ]] || echo '+ ln -t /nix/store/.links/' *
    [[   ${args[dry-run]:-} ]] || printf '%s\0' * | @xargs@ -r0 -- ln -t /nix/store/.links/ &>/dev/null || true #if any files already existed in »/nix/store/.links/«, then »do-install« used those
    status 'saved hardlinks to new files'
}


# Remove old components from the store:
function do-delete {
    if [[ -e $dir/.data-end && ${args[skip-completed]:-} && ! -e $dir/.delete-paths ]] ; then return 0 ; fi
    if [[ ! -e $dir/.delete-paths ]] ; then echo "Can't delete old store components, meta file is missing" ; exit 1 ; fi
    while IFS= read -r path ; do
        ( $v1 ; "${run[@]}" rm -rf /nix/store/"$path" )
    done <"$dir"/.delete-paths
    rm "$dir"/.delete-paths
    status 'removed old components from the store'
}


# Prune hardlinks to files no longer needed:
function do-prune-links {
    if [[ ! ${args[maintain-links]:-} && $links != /nix/store/.links ]] ; then rm -f "$dir"/.prune-links ; return 0 ; fi
    if [[ -e $dir/.data-end && ${args[skip-completed]:-} && ! -e $dir/.prune-links ]] ; then return 0 ; fi
    if [[ ! -e $dir/.prune-links ]] ; then echo "Can't prune old hardlinks, meta file is missing" ; exit 1 ; fi
    while IFS= read -r hash ; do
        ( $v1 ; "${run[@]}" unlink /nix/store/.links/$hash &>/dev/null || true )
    done <"$dir"/.prune-links
    rm "$dir"/.prune-links
    status 'pruned hardlinks to files no longer needed'
}


# Remove instructions and temporary hardlinks:
function do-cleanup {
    if [[ ! -e $dir ]] ; then return 0 ; fi ; cd "$dir"
    if [[ ! ${args[force-cleanup]:-} ]] && [[ -e .restore-links || -e .cerate-paths || -e .delete-paths || -e .prune-links ]] ; then echo "Won't do cleanup, some meta files weren't processed yet" ; exit 1 ; fi
    toplevelPaths=$( cat ./.toplevel-paths )
    rm -rf "$dir"
    status 'removed instructions and temporary hardlinks'
}


@genericArgParse@
@genericArgHelp@
@genericArgVerify@

#set -x
main "$@"
