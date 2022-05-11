#!@shell@
set -eu ; { { # Normal output/logging (anything written to fd1) will go to stderr, program stream output needs to be written to fs3 » >&3 «.

: ${1:?"Required: The colon-separated list of wanted store artifacts."}
: ${2:?"Required: The colon-separated list of existing store artifacts."}


## Creates a multi-map called »__ret__« (in the calling scope) that, for all files in a set of artifacts, contains the hash of the file as kay and a »//« separated list of all paths linking to that file as value.
function find-files { # ...: paths
    paths=( "$@" ) ; declare -g -A __ret__=( )
    while IFS= read -r -d $'\0' path ; do
        path=${path/\/nix\/store\//}
        while [[ $path == *//* ]] ; do path=${path/\/\//\/} ; done # replace any »//+« by »/« (shouldn't happen)
        #echo "path=$path"
        hash=$(@narHash@ /nix/store/"$path")
        if [[ ${__ret__[$hash]:-} ]] ; then path=${__ret__[$hash]}//$path ; fi
        __ret__[$hash]=$path
    done < <(find -P "${paths[@]/#/\/nix\/store\/}" -type f,l,p,s -print0)
}

## Given a colon-separated list of store paths, outputs a »\n« terminated, sorted, and deduplicated list of all the store paths they depend on.
function resolve-dependencies {( set -eu # 1: paths
    IFS=: paths=( $1 )
    { for path in "${paths[@]}" ; do
        path=$( realpath "$path" || ( cd /nix/store/ && realpath "$path" ) )
        nix path-info -r "$path" | while IFS= read -r path ; do
            printf "%s\n" "${path/\/nix\/store\//}"
        done
    done ; } | LC_ALL=C sort | uniq
)}

## Outputs a simple and very compact script that can be interpreted on the target to create all file links that make up the new store artifacts.
#  This looks pretty dense (and bash may not be the perfect language here), but this follows the description in "`cerate-paths` Linking Script" pretty much line by line.
function cerate-paths-script {( set -eu # void
    declare -A files=( ) ; for hash in "${!linkHM[@]}" ; do
        while IFS= read -r -d $'\0' path ; do
            files[$path]=$hash
        done < <(<<< "${linkHM[$hash]}//" sed 's;//;\x0;g')
    done
    s='/' ; l='\0' ; #s=' ' ; l='\n'
    cwd=( ) ; prev= ; while IFS= read -r -d $'\0' path ; do
        if [[ "${prev%%/*}" != "${path%%/*}" ]] ; then printf "r$l" ; cwd=( ) ; fi ; prev=$path
        IFS=/ dirs=( $path ) ; unset IFS ; name=${dirs[-1]} ; unset dirs[-1]
        j=0 ; while [[ ${cwd[$j]:-} && ${dirs[$j]:-} && ${cwd[$j]} == ${dirs[$j]} ]] ; do j=$(( j + 1 )) ; done
        #echo ${#cwd[@]}-${#dirs[@]}-$j' ; '"${cwd[@]}"' ; '"${dirs[@]}" 1>&2
        for (( i = ${#cwd[@]} - 1 ; i >= j ; i-- )); do printf "p$l" ; unset cwd[$i] ; done
        for (( i = j ; i < ${#dirs[@]} ; i++ )); do printf "d$s%s$l" "${dirs[$i]}" ; cwd+=( "${dirs[$i]}" ) ; done
        if [[ $path != "${cwd:+$(printf '%s/' "${cwd[@]}")}$name" ]] ; then echo "$(printf '%s/' "${cwd[@]}")$name"' != '$path 1>&2 ; exit 1 ; fi # (just a sanity check)
        mode=- ; [[ $(stat --format=%A /nix/store/"$path") != *x* ]] || mode=x
        printf "f$s%s$s%s$s%s$l" "${files[$path]}" "$mode" "$name"
    done < <(printf '%s\0' "${!files[@]}" | LC_ALL=C sort --zero-terminated)
)}

## Outputs the »\n« terminated (or separated?) list of all entries in »base« that do not occur in »remove« (where the latter two are »\n« separated).
function list-complement {( set -eu # 1: base, 2: remove
    base=$1 ; remove=$2
    # Of the base list once and the remove list twice, return everything that only occurs once:
    <<< "${base}"$'\n'"${remove}"$'\n'"${remove}" LC_ALL=C sort | uniq -u
    # this could be done a lot more efficient (esp. when both lists are already sorted)
)}

wantedArts=$(resolve-dependencies "$1") # artifacts we need to have
#    declare -p wantedArts 1>&3
existingArts=$(resolve-dependencies "$2") # artifacts we currently have
#    declare -p existingArts 1>&3

createArts=$(list-complement "$wantedArts" "$existingArts") # artifacts we create
#    declare -p createArts 1>&3
pruneArts=$(list-complement "$existingArts" "$wantedArts") # artifacts we keep
#    declare -p pruneArts 1>&3
keepArts=$(list-complement "$existingArts" "$pruneArts") # artifacts we no longer need
#    declare -p keepArts 1>&3

find-files $createArts ; s=$(declare -p __ret__) ; eval "${s/__ret__/linkHM}" # files linked from artifacts that we create (i.e. will create new links to)
#    declare -p linkHM 1>&3
find-files $keepArts ; s=$(declare -p __ret__) ; eval "${s/__ret__/keepHM}" # files linked from artifacts that we keep
#    declare -p keepHM 1>&3
find-files $pruneArts ; s=$(declare -p __ret__) ; eval "${s/__ret__/oldHM}" # files linked from artifacts that we can delete
#    declare -p oldHM 1>&3

pruneHL=$(list-complement "$(printf '%s\n' "${!oldHM[@]}")" "$(printf '%s\n' "${!keepHM[@]}")"$'\n'"$(printf '%s\n' "${!linkHM[@]}")") # files we no longer need
#    declare -p pruneHL 1>&3
uploadHL=$(list-complement "$(printf '%s\n' "${!linkHM[@]}")" "$(printf '%s\n' "${!keepHM[@]}")"$'\n'"$(printf '%s\n' "${!oldHM[@]}")") # files we need but don't have
#    declare -p uploadHL 1>&3
declare -A uploadHM=( ) ; [[ ! $uploadHL ]] || eval 'uploadHM=( ['"${uploadHL//$'\n'/']="x" ['}"']="x" )' # (the above as map <hash,"x">)
#    declare -p uploadHM 1>&3
declare -A restoreHM=( ) ; for hash in "${!linkHM[@]}" ; do [[ ${uploadHM[$hash]:-} ]] || restoreHM[$hash]=${linkHM[$hash]} ; done # files we need and have (just not in the .links dir)
#    declare -p restoreHM 1>&3

( dir=$(mktemp -d) ; trap "rm -rf $dir" EXIT ; cd $dir ; (

    ( for hash in "${!restoreHM[@]}" ; do printf "%s=%s\0" "$hash" "${restoreHM[$hash]%%//*}" ; done ) >./.restore-links
    cerate-paths-script >./.cerate-paths
    <<< "$pruneArts" cat >./.delete-paths
    <<< "$pruneHL" cat >./.prune-links

    ls -A | tar --create --files-from=- --owner=root:0 --group=root:0 --to-stdout 1>&3
) )

( cd /nix/store/.links/ ; <<< "$uploadHL" tar --create --files-from=- --owner=root:0 --group=root:0 --to-stdout ) 1>&3 # (this is actually the only place where the ».links« dir is used)

} 1>&2 ; } 3>&1 # stdout => stderr ; fd3 => stdout
