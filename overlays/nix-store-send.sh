#!@shell@
set -eu ; { { # Normal output/logging (anything written to fd1) will go to stderr, program stream output needs to be written to fs3 (» >&3 «).

## Creates a multi-map called »__ret__« (in the calling scope) that, for all files in a set of artifacts, contains the hash of the file as kay and a »//« separated list of all paths linking to that file as value.
function find-files { # ...: paths
    paths=( "$@" ) ; declare -g -A __ret__=( ) ; [[ $# != 0 ]] || return 0
    while IFS= read -r -d $'\0' path ; do
        path=${path/\/nix\/store\//}
        while [[ $path == *//* ]] ; do path=${path/\/\//\/} ; done # replace any »//+« by »/« (shouldn't happen)
        #echo "path=$path"
        hash=$(@narHash@ /nix/store/"$path")
        if [[ ${__ret__[$hash]:-} ]] ; then path=${__ret__[$hash]}//$path ; fi
        __ret__[$hash]=$path
    done < <(find -P "${paths[@]/#/\/nix\/store\/}" -type f,l,p,s -print0)
}

## Given a colon-separated list of store paths, outputs a »\n« terminated, sorted, and deduplicated list of normalized and ensured-to-be-existing relative paths.
function normalize-paths {( set -eu # 1: paths
    IFS=: paths=( $1 )
    { for path in "${paths[@]}" ; do original=$path ; (
        if [[ $path == /nix/store/* ]] ; then path="${path/\/nix\/store\//}" ; fi
        path="${path/\/*/}" ; if [[ ! -e /nix/store/$path ]] ; then echo "$path does not exist in /nix/store/" ; exit 1 ; fi
        printf "%s\n" "$path"
    ) ; done ; } | LC_ALL=C sort | uniq
)}

## Given a list of store paths as arguments, outputs a »\n« terminated, sorted, and deduplicated list of all the store paths they depend on.
function resolve-dependencies {( set -eu # ...: paths
    { for path in "$@" ; do
        @nix@ --offline path-info -r /nix/store/"$path" | while IFS= read -r path ; do
            printf "%s\n" "${path/\/nix\/store\//}"
        done
    done ; } | LC_ALL=C sort | uniq
)}

## Outputs a simple and very compact script that can be interpreted on the target to create all file links that make up the new store artifacts.
#  This looks pretty dense (and bash may not be the perfect language here), but it follows the description in "`cerate-paths` Linking Script" pretty much line by line.
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

function prepare-sending {

    generic-arg-parse "$@"

    beforeTop=( $( normalize-paths "${argv[0]:?"Required: Store components expected to exist before applying the stream (as colon-separated list)."}" ) )
    afterTop=(  $( normalize-paths "${argv[1]:?"Required: Store components that will instead exist after applying the stream (as colon-separated list)."}" ) )
    if [[ "${afterTop[@]}" == "${beforeTop[@]}" ]] ; then echo "The »after« and »before« arguments are identical" ; exit 1 ; fi

    verboseShow=: ; if [[ ${args[verbose]:-} ]] ; then verboseShow='declare -p' ; fi

    afterComps=$( resolve-dependencies "${afterTop[@]}" ) # artifacts we need to have
    $verboseShow afterComps
    beforeComps=$( resolve-dependencies "${beforeTop[@]}" ) # artifacts we currently have
    $verboseShow beforeComps

    createComps=$( list-complement "$afterComps" "$beforeComps" ) # artifacts we create
    $verboseShow createComps
    pruneComps=$( list-complement "$beforeComps" "$afterComps" ) # artifacts we keep
    $verboseShow pruneComps
    keepComps=$( list-complement "$beforeComps" "$pruneComps" ) # artifacts we no longer need
    $verboseShow keepComps

    find-files $createComps ; s=$(declare -p __ret__) ; eval "${s/__ret__/-g linkHM}" # files linked from artifacts that we create (i.e. will create new links to)
    $verboseShow linkHM
    find-files $keepComps ; s=$(declare -p __ret__) ; eval "${s/__ret__/-g keepHM}" # files linked from artifacts that we keep
    $verboseShow keepHM
    find-files $pruneComps ; s=$(declare -p __ret__) ; eval "${s/__ret__/-g oldHM}" # files linked from artifacts that we can delete
    $verboseShow oldHM

    pruneHL=$( list-complement "$( printf '%s\n' "${!oldHM[@]}" )" "$( printf '%s\n' "${!keepHM[@]}" )"$'\n'"$( printf '%s\n' "${!linkHM[@]}" )" ) # files we no longer need
    $verboseShow pruneHL
    uploadHL=$( list-complement "$( printf '%s\n' "${!linkHM[@]}" )" "$( printf '%s\n' "${!keepHM[@]}" )"$'\n'"$( printf '%s\n' "${!oldHM[@]}" )" ) # files we need but don't have
    $verboseShow uploadHL
    #declare -g -A uploadHM=( ) ; [[ ! $uploadHL ]] || eval 'declare -g -A uploadHM=( ['"${uploadHL//$'\n'/']="x" ['}"']="x" )' # (the above as map <hash,"x">)
    #$verboseShow uploadHM
    restoreHL=$( list-complement "$( printf '%s\n' "${!linkHM[@]}" )" "$uploadHL" ) # files we need and have (just not in the .links dir)
    $verboseShow restoreHL
    #declare -g -A restoreHM=( ) ; for hash in "${!linkHM[@]}" ; do [[ ${uploadHM[$hash]:-} ]] || restoreHM[$hash]=${linkHM[$hash]} ; done # files we need and have (just not in the .links dir)
    #$verboseShow restoreHM

}

# »/nix/store/.links/« is not always available, so get the files from the lookup maps:
function get-file-path { # 1: hash
    local hash=$1
    if [[ ${keepHM[$hash]:-} ]] ; then printf %s "${keepHM[$hash]%%//*}" ; return 0 ; fi
    if [[  ${oldHM[$hash]:-} ]] ; then printf %s  "${oldHM[$hash]%%//*}" ; return 0 ; fi
    if [[ ${linkHM[$hash]:-} ]] ; then printf %s "${linkHM[$hash]%%//*}" ; return 0 ; fi
    echo "Can't locate file $hash" ; exit 1
}

function show-stats { # 1: dest
    dest=$1 ; if (( dest > 0 )) &>/dev/null ; then dest='/proc/self/fd/'$dest ; fi
    local sendCount=$( wc -l <<<"$uploadHL" )  ; local sendSize=0 ; for hash in $uploadHL  ; do let sendSize+=$( stat --printf="%s" /nix/store/$(get-file-path $hash) || echo 0 ) || true ; done
    local linkCount=$( wc -l <<<"$restoreHL" ) ; local linkSize=0 ; for hash in $restoreHL ; do let linkSize+=$( stat --printf="%s" /nix/store/$(get-file-path $hash) || echo 0 ) || true ; done
    (
        echo "Sending ${#afterTop[@]} root path${afterTop[1]:+s} referencing $( <<<"$afterComps" wc -l ) store paths"
        echo "onto    ${#beforeTop[@]} root path${beforeTop[1]:+s} referencing $( <<<"$beforeComps" wc -l ) store paths,"
        echo "therefore uploading  ${sendCount} files with an overall size of ${sendSize} bytes,"
        echo "and reusing existing ${linkCount} files with an overall size of ${linkSize} bytes."
    ) 1>$dest
}

function send-stream { # 1: name, 2: flags, 3: size
    local name=( $1 ) ; local flags=( $2 ) ; local size=$(( $3 - 0 )) ; (( size > 0 )) || size=0
    #printf "%s %s %s\n" ${name:-.} ${flags:--} $size
    printf "%s %s %s\n" ${name:-.} ${flags:--} $size 1>&3 # (the values of name and flags might be crap, but this always sends three fields)
    cat - /dev/zero | head -c $size 1>&3 ; printf '\n' 1>&3
}
function send-file { # 1: name, 2: path
    local flags= ; if [[ -L "$2" ]] ; then flags+=l ; elif [[ $( stat --format=%A "$2" ) == *x* ]] ; then flags+=x ; fi
    if [[ $flags == l ]] ; then readlink -n -- "$2" ; else cat -- "$2" ; fi | send-stream "$1" "$flags" "$( stat --printf="%s" "$2" || : )"
}

function do-send { ( dir=$(mktemp -d) ; trap "rm -rf $dir" EXIT ; cd $dir ; (

    toplevel="${afterTop[@]}" ; <<< "$toplevel" send-stream .toplevel-paths - ${#toplevel}

    lines=( ) ; size=0 ; for hash in $restoreHL ; do line=${hash}=$(get-file-path $hash) ; lines+=($line) ; let size+=${#line}+1 ; done
    printf "%s\0" "${lines[@]}" | send-stream .restore-links - $size

    cerate-paths-script >./.cerate-paths ; send-file .cerate-paths ./.cerate-paths

    <<< "$pruneComps" send-stream .delete-paths - ${#pruneComps}
    <<< "$pruneHL"    send-stream .prune-links  - ${#pruneHL}

    : | send-stream .meta-end - 0

    if [[ ${args[no-names]:-} ]] ; then
        while IFS= read -r hash ; do
            send-file . /nix/store/$(get-file-path $hash)
        done <<< "$uploadHL"
    else
        while IFS= read -r hash ; do
            send-file $hash /nix/store/$(get-file-path $hash)
        done <<< "$uploadHL"
    fi

    : | send-stream .data-end - 0

) ) }

@genericArgParse@

prepare-sending "$@"
[[ ! ${args[stats]:-} ]] || show-stats "${args[stats]}"
[[ ${args[dry-run]:-} ]] || do-send

} 1>&2 ; } 3>&1 # stdout => stderr ; fd3 => stdout
