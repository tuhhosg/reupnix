dirname: inputs: let
    lib = inputs.self.lib.__internal__;
in rec {

    ## From a host's »default.nix«, import the »machine.nix« configuration, any »systems/« configurations, and enable the defaults for target devices.
    #  The reason why this is a library function and not part of the »../target/defaults« module is that importing based on a config value is not possible, and config values are the only way to pass variables (»dirname«) to a module (other than the global module function arguments, but given that they are global, they are a pretty bad way to pass variables).
    importMachineConfig = inputs: dirname: {
        th.target.defaults.enable = true;
        imports = [ (lib.fun.importWrapped inputs "${dirname}/machine.nix").module ];
        specialisation = lib.mapAttrs (name: path: { configuration = { imports = [
            { th.target.specs.name = name; }
            (lib.fun.importWrapped inputs path).module
        ]; _file = "${dirname}/misc.nix#specialisation"; }; }) (lib.fun.getNixFiles "${dirname}/systems");
        installer.scripts.extra-setup = { path = ../utils/setup.sh; order = 1500; }; # (for reasons of weirdness, this only works when placed here)
    };

    copy-files = pkgs: name: attrs: let
        copy = pkgs.runCommandLocal name { } ''
            mkdir $out
            ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: path: let dir = builtins.dirOf name; in (if dir != "." then "mkdir -p $out/${lib.escapeShellArg dir} ; " else "") + ''cp -aT ${lib.escapeShellArg path} $out/${lib.escapeShellArg name}'') attrs)}
        '';
    in lib.mapAttrs (name: _: "${copy}/${name}") attrs;

    ## Extracts the result of »pkgs.dockerTools.pullImage«:
    extract-docker-image = pkgs: image: pkgs.runCommandLocal (if lib.isString image then "container-image" else "docker-image-${image.imageName}-${image.imageTag}") { inherit image; outputs = [ "out" "info" ]; } ''
        set -x
        tar -xf $image
        ls -al .
        layers=( $( ${pkgs.jq}/bin/jq -r '.[0].Layers|.[]' manifest.json ) )
        mkdir -p $out
        for layer in "''${layers[@]}" ; do
            tar --anchored --exclude='dev/*' -tf $layer | ( grep -Pe '(^|/)[.]wh[.]' || true ) | while IFS= read -r path ; do
                if [[ $path == */.wh..wh..opq ]] ; then
                    ( shopt -s dotglob ; rm -rf $out/"''${path%%.wh..wh..opq}"/* )
                else
                    name=$( basename "$path" ) ; rm -rf $out/"$( dirname "$path" )"/''${name##.wh.}
                fi
            done
            tar --anchored --exclude='dev/*' -C $out -xf $layer -v |
            ( grep -Pe '(^|/)[.]wh[.]' || true ) | while IFS= read -r path ; do
                name=$( basename "$path" ) ; rm -rf $out/"$path"
            done
            chmod -R +w $out
        done
        mkdir -p $info
        cp ./manifest.json $info/
        config=$( ${pkgs.jq}/bin/jq -r '.[0].Config' manifest.json || true )
        [[ ! $config ]] || cp ./"$config" $info/config.json
        stat --printf='%s\t%n\n' "''${layers[@]}" | LC_ALL=C sort -k2 > $info/layers
    '';

}
