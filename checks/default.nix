dirname: inputs: pkgs: let
    lib = inputs.self.lib.__internal__; test = lib.th.testing pkgs;
    #imports = lib.fun.importFilteredFlattened dirname inputs { except = [ "default" ]; };
    imports = lib.fun.importFilteredFlattened dirname inputs { except = if (pkgs.system == "aarch64-linux") then [ # For some reason, importing the files (even when not intending to evaluate anything defined in them), some import-from-derivation happens, where the derivations are x64 ones that fail to build on aarch64 (even with qemu binfmt registration). Strange stuff. So let's just disable it.
        "container-sizes" "default"  "demo" /* "install-size" */ "nix-copy-update" /* "reconfig-time" */ "nix_store_send" "stream-rsync" "stream-size" "stream-update" "test" "update-glibc"
    ] else [ "default" ]; };
    wrap = script: ''
        set -eu
        PATH=${lib.makeBinPath (lib.unique (map (p: p.outPath) (lib.filter lib.isDerivation pkgs.stdenv.allowedRequisites)))}
        export out=$PWD/out ; cd /"$(mktemp -d)" && [[ $PWD != / ]] || exit 1
        if [[ $(id -u) == 0 ]] ; then
            ${pkgs.util-linux}/bin/mount -t tmpfs tmpfs $PWD ; cd $PWD ; trap "${pkgs.util-linux}/bin/umount -l $PWD ; rmdir $PWD" exit # requires root
        else
            trap "find $PWD -type d -print0 | xargs -0 chmod 700 ; rm -rf $PWD" exit # can be slow
        fi
        ${lib.fun.extractBashFunction (builtins.readFile lib.inst.setup-scripts.utils) "generic-arg-parse"}
        unset SUDO_USER ; generic-arg-parse "$@"
        ( trap - exit
            if [[ ''${args[debug]:-} ]] ; then set -x ; fi
            ${script}
        )
    '';
    checks = let
        mkCheck = name: script: attrs: (pkgs.writeShellScript "check-${name}.sh" (wrap script)).overrideAttrs (old: {
            passthru = (old.passthru or { }) // attrs;
        });
    in lib.fun.mapMergeUnique (name: import': let import = import' pkgs; in if (builtins.isString import) then (
        { ${name} = mkCheck name import { script = import; }; }
    ) else if (builtins.isString (import.script or null)) then (
        { ${name} = mkCheck name import.script import; }
    ) else (lib.fun.mapMerge (name': script:
        { "${name}-${name'}" = mkCheck name script import; }
    ) import.scripts)) imports;
    apps = (lib.fun.mapMerge (k: v: { "check:${k}" = { type = "app"; program = "${v}"; }; }) checks) // {
        "check:all" = { type = "app"; program = "${pkgs.writeShellScript "check-all.sh" ''
            failed=0 ; warning='"!!!!!!!!!!!!!!!!!!!!!!!'
            ${(lib.concatStringsSep "\n" (lib.mapAttrsToList (k: v: ''
                echo ; echo ; ${test.frame ''echo "Running check:${k}:"''} ; echo
                ${v} || { failed=$? ; echo "$warning check:${k} failed with $failed $warning" 1>&2 ; }
            '') (builtins.removeAttrs checks [ "demo" "test" ])))}
            exit $failed
        ''}"; };
    } // (let inherit (pkgs) system; in let
        pkgs = import inputs.latest-nixpkgs { inherit system; };
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
    in lib.fun.mapMerge (name: { "eval:${name}" = rec { type = "app"; derivation = pkgs.writeShellScript "${name}.py.sh" ''
        exec ${python3}/bin/python3 ${dirname}/../lib/data/${name}.py ./out/
    ''; program = "${derivation}"; }; }) [ "dref" "fig-oci_combined" "fig-reboot" "fig-update-size" ]);
in { inherit checks apps; packages = checks; }
