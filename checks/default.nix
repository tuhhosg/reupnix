dirname: inputs: pkgs: let
    lib = inputs.self.lib.__internal__; test = lib.th.testing pkgs;
    imports = lib.fun.importFilteredFlattened dirname inputs { except = [ "default" ]; };

    wrap = script: ''
        set -eu
        PATH=${lib.makeBinPath (lib.unique (map (p: p.outPath) (lib.filter lib.isDerivation pkgs.stdenv.allowedRequisites)))}
        export out=$PWD/out ; cd /"$(mktemp -d)" && [[ $PWD != / ]] || exit 1
        if [[ $(id -u) == 0 ]] ; then
            ${pkgs.util-linux}/bin/mount -t tmpfs tmpfs $PWD ; cd $PWD ; trap "${pkgs.util-linux}/bin/umount -l $PWD ; rmdir $PWD" exit # requires root
        else
            trap "find $PWD -type d -print0 | xargs -0 chmod 700 ; rm -rf $PWD" exit # can be slow
        fi
        source ${lib.fun.bash.generic-arg-parse}
        unset SUDO_USER ; generic-arg-parse "$@"
        ( trap - exit
            if [[ ''${args[debug]:-} ]] ; then set -x ; fi
            ${script}
        )
    '';

    checks = let checks = let
        mkCheck = name: script: attrs: (pkgs.writeShellScriptBin "check-${name}.sh" (wrap script)).overrideAttrs (old: {
            passthru = (old.passthru or { }) // attrs;
        });
    in lib.fun.mapMerge (name: _import': let _import = _import' pkgs; in if (_import?script) then (
        { ${name} = mkCheck name _import.script _import; }
    ) else lib.fun.mapMerge (suffix: script: (
        { "${name}-${suffix}" = mkCheck "${name}:${suffix}" script _import; }
    )) _import.scripts) imports; in checks // {
        all = pkgs.writeShellScriptBin "check-all.sh" ''
            failed=0 ; warning='"!!!!!!!!!!!!!!!!!!!!!!!'
            ${(lib.concatStringsSep "\n" (lib.mapAttrsToList (k: v: ''
                echo ; echo ; ${test.frame ''echo "Running check:${k}:"''} ; echo
                ${v} || { failed=$? ; echo "$warning check:${k} failed with $failed $warning" 1>&2 ; }
            '') (builtins.removeAttrs checks [ "demo" "test" ])))}
            exit $failed
        '';
    };

    apps = (lib.fun.mapMerge (k: v: {
        "check:${k}" = { type = "app"; program = "${v}"; };
    }) checks) // (let inherit (pkgs) system; in let
        pkgs = import inputs.nixpkgs-unstable { inherit system; };
        mkPipPackage = name: version: sha256: deps: extra: pkgs.python3Packages.buildPythonPackage ({
            pname = name; version = version; propagatedBuildInputs = deps;
            src = pkgs.python3Packages.fetchPypi { pname = name; version = version; sha256 = sha256; };
        } // extra);
        python3 = pkgs.buildPackages.python3.withPackages (pip3: (builtins.attrValues rec {
            inherit (pip3) ipykernel python-magic numpy pandas patsy plotnine mizani matplotlib setuptools statsmodels;
            plydata = mkPipPackage "plydata" "0.4.3" "Lq2LbAzy+fSDtvAXAmeJg5Qlg466hAsWDXRkOVap+xI=" [ pip3.pandas pip3.pytest ] { };
            versuchung = mkPipPackage "versuchung" "1.4.1" "iaBuJczQiJHLL6m8yh3RXFMrG9astbwIT+V/sWuUQW4=" [ pip3.papermill ] { doCheck = false; };
            osgpy = mkPipPackage "osgpy" "0.1.3" "ogEtmqOYKJ+7U6QE63qVR8Z8fofBApThu66QsbYpLio=" [ pip3.pandas plotnine plydata versuchung ] { };
        }));
    in lib.fun.mapMerge (name: { "eval:${name}" = rec { type = "app"; derivation = pkgs.writeShellScriptBin "${name}.py.sh" ''
        exec ${python3}/bin/python3 ${dirname}/../lib/data/${name}.py ./out/
    ''; program = "${derivation}"; }; }) [ "dref" "fig-oci_combined" "fig-reboot" "fig-update-size" ]);

in { inherit checks apps; packages = checks; }
