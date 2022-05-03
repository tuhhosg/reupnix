#!@shell@
set -eu

{ { # Normal output/logging (anything written to fd1) will go to stderr, program stream output needs to be written to fs3 » >&3 «.

## Creates a multi-map called »name« (in the calling scope) that, for all files in a set of artifacts, contains the hash if the file as kay and a »//« separated list of all paths linking to that file as value.

function makeHashMap { # paths
    paths=( "$@" ) ; declare -g -A __ret__=( )
    while IFS= read -r -d $'\0' path ; do
        path=${path/\/nix\/store\//}
        while [[ $path == *//* ]] ; do path=${path/\/\//\/} ; done # replace any »//+« by »/« (should never happen)
        #echo "path=$path"
        hash=$(@narHash@ /nix/store/"$path")
        if [[ ${__ret__[$hash]:-} ]] ; then path=${__ret__[$hash]}//$path ; fi
        __ret__[$hash]=$path
    done < <(find -P "${paths[@]/#/\/nix\/store\/}" -type f,l,p,s -print0)
}

function resolve-dependencies {( set -eu # 1: paths
    IFS=: paths=( $1 )
    { for path in "${paths[@]}" ; do
        path=$( realpath "$path" || ( cd /nix/store/ && realpath "$path" ) )
        nix path-info -r "$path" | while IFS= read -r path ; do
            printf "%s\n" "${path/\/nix\/store\//}"
        done
    done ; } | LC_ALL=C sort | uniq
)}

#set -x
#resolve-dependencies "$1"
makeHashMap $(resolve-dependencies "$1") ; s=$(declare -p __ret__) ; eval "${s/__ret__/wantedArts}"


declare -p wantedArts

} 1>&2 ; } 3>&1 # stdout => stderr ; fd3 => stdout
