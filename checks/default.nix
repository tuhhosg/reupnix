dirname: inputs@{ self, nixpkgs, ...}: pkgs: let
    inherit (inputs.self) lib;
    scripts = self.lib.wip.importFilteredFlattened dirname inputs { };
    tools = lib.unique (map (p: p.outPath) (lib.filter lib.isDerivation pkgs.stdenv.allowedRequisites));
    wrap = script: ''
        set -eu
        PATH=${lib.concatMapStringsSep ":" (pkg: "${pkg}/bin") tools}
        cd /$(mktemp -d) ; [[ $PWD != / ]] || exit 1
        if [[ $(id -u) == 0 ]] ; then
            ${pkgs.util-linux}/bin/mount -t tmpfs tmpfs $PWD ; cd $PWD ; trap "${pkgs.util-linux}/bin/umount -l $PWD ; rmdir $PWD" exit # requires root
        else
            trap "find $PWD -type d -print0 | xargs -0 chmod 700 ; rm -rf $PWD" exit # can be slow
        fi
        ${lib.wip.extractBashFunction (builtins.readFile lib.wip.setup-scripts.utils) "generic-arg-parse"}
        unset SUDO_USER ; generic-arg-parse "$@"
        ( trap - exit
            if [[ ''${args[debug]:-} ]] ; then set -x ; fi
            ${script pkgs}
        )
    '';
    checks = lib.mapAttrs (name: script: pkgs.writeShellScript "check-${name}.sh" (wrap script)) scripts;
    apps = lib.wip.mapMerge (k: v: { "check:${k}" = { type = "app"; program = "${v}"; }; }) checks;
in { inherit checks apps; }
