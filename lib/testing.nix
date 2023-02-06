dirname: { self, nixpkgs, wiplib, ...}: let
    inherit (wiplib) lib;
in pkgs: rec {
    ##
    # Library functions for testing (or rather assessment) of the properties of the configurations and scripts.
    # To be used exclusively in »../checks/« as: inherit (lib.th.testing pkgs) toplevel override unpinInputs ...;
    ##

    toplevel = system: system.config.system.build.toplevel;
    override = system: config: system.extendModules { modules = [ config ]; };
    unpinInputs = system: override system { th.hermetic-bootloader.slots.currentLabel = "bt-dummy"; wip.base.includeInputs = lib.mkForce { }; }; # to be able to modify the test sources without affecting the tested systems
    resize = size: system: override system { wip.fs.disks.devices.primary.size = lib.mkForce size; };
    dropRefs = builtins.unsafeDiscardStringContext; # Use this when referencing something from a »run-in-vm« test that should not be included in the initial installation.

    time = cmd: ''echo '+' ${cmd} ; ${pkgs.time}/bin/time -f "\t%E real,\t%U user,\t%S sys" ${cmd}'';
    disk-usage = ''echo "disk usage: $( df --block-size=1 --output=used -- /system | tail -n+2 )"'';
    frame = script: "echo '================='\n${script}\necho '================='";

    measure-installation = system: measurement: let
        system' = override system ({
            wip.fs.disks.postInstallCommands = ''
                ( ${measurement} ) &>$( if [[ -e /tmp/shared ]] ; then echo /tmp/shared/log ; else echo ''${args[x-tmp]}/log ; fi )
            '';
        });
        scripts = lib.wip.writeSystemScripts { system = system'; pkgs = pkgs; };
    in ''(
        tmp=$( mktemp -d ) && trap "rm -rf '$tmp'" EXIT || exit
        cmd=( ${scripts} install-system $tmp/image --no-inspect --toplevel=${toplevel system} --vm-shared=$tmp --x-tmp=$tmp )
        if [[ ''${args[debug]:-} ]] ; then ''${cmd[@]} --debug || exit ; else ''${cmd[@]} --quiet || exit ; fi
        cat $tmp/log || exit
    )'';

    ## Copies all (transitive) dependencies of »root« into a single directory with the same structure as »/nix/store/« (without »./.links«).
    collect-deps = root: pkgs.runCommandLocal "collected-deps" { requiredSystemFeatures = [ "recursive-nix" ]; outputs = [ "out" "clean" ]; } ''
        mkdir $out ; ${pkgs.nix}/bin/nix --extra-experimental-features 'nix-command' --offline --auto-optimise-store copy --no-check-sigs --to $out ${root}
        chmod -R +w $out ; mv $out/nix/store/* $out ; rm -rf $out/nix
        cp -aT $out $clean ; find $clean -type l -print0 | xargs -0 rm
    '';

    du-deps = root: pkgs.runCommandLocal "du-deps" { requiredSystemFeatures = [ "recursive-nix" ]; } ''
        du --apparent-size --block-size=1 --summarize $( ${pkgs.nix}/bin/nix --extra-experimental-features 'nix-command' --offline path-info -r /nix/store/"$path" ${root} ) | cut -f1 >$out
    '';

    ## Merges all (transitive) dependencies of »root« into a single directory. Dependencies that are (top-level) files will be placed in »/~files~«, symlinks are ignored/removed.
    merge-deps = root: pkgs.runCommandLocal "merged-deps" { requiredSystemFeatures = [ "recursive-nix" ]; } ''
        mkdir -p $out/~files~ ; ${pkgs.nix}/bin/nix --extra-experimental-features 'nix-command' --offline path-info -r ${root} | while IFS= read -r item ; do
            if [[ ! -d $item ]] ; then cp -t $out/~files~/ $item ; continue ; fi
            ( cd $item ; find -type f ) | while IFS= read -r path ; do
                #[[ ! -d $out/$path ]] || continue # this should not happen
                mkdir -p $out/"$(dirname "$path")"
                cp --backup=numbered --no-preserve=mode,ownership,timestamps -r -T $item/"$path" $out/"$path"
            done
        done
    '';

    ## Builds a »nix-store-send« stream inside the nix store, and returns »./stats« and the »./stream« itself.
    nix-store-send = old: new: flags: let
        old-tl = if old == null then pkgs.runCommandLocal "empty" { } "mkdir $out" else toplevel old;
    in pkgs.runCommandLocal "send-stream-${old-tl.name}-${(toplevel new).name}" {
        requiredSystemFeatures = [ "recursive-nix" ];
    } ''(
        mkdir -p $out ; set -x ; ${pkgs.nix-store-send}/bin/nix-store-send --verbose --stats=$out/stats ${flags} -- ${old-tl} ${toplevel new} 1>$out/stream
    )'';

    ## Builds »system«, installs it to a temporary image, then for every »{ pre?, test, }« in »tests«, boots the image in qemu, waits for SSH to come up, optionally runs »pre« (with »$ssh« set), runs »test« via ssh, and powers down the VM. Aborts if »pre« or »test« fail.
    run-in-vm = system: opts@{ quiet ? false, ... }: tests: let
        system' = override system ({
            wip.services.dropbear.rootKeys = lib.readFile "${self}/utils/res/ssh_testkey_1.pub";
            system.extraDependencies = [ (toplevel system) ] ++ map (_:_.test) tests'; # to include the test files in the installation
        } // (if opts?override then { imports = [ opts.override ]; } else { }));
        toFile = type: i: code: pkgs.writeShellScript "${type}-${toString i}.sh" "set -eu\n${code}";
        tests' = lib.imap0 (i: { pre ? "", test, }: { pre = if pre == "" then "true" else toFile "pre-test" i pre; test = toFile "test" i test; }) (map (test: if builtins.isString test then { inherit test; } else test) tests);
        known_hosts = builtins.toFile "dummy_known_hosts" ''[127.0.0.1]:* ${lib.readFile "${self}/utils/res/dropbear_ecdsa_host_key.pub"}'';
        log = message: if quiet then "" else ''echo "${message}" ;'';
        scripts = lib.wip.writeSystemScripts { system = system'; pkgs = pkgs; };
    in ''(
        ${log "installing system: ${toplevel system'}"}
        cp ${self}/utils/res/ssh_testkey_1 ./ssh_testkey_1 2>/dev/null || true ; chmod 400 ./ssh_testkey_1 || exit
        port=${bash-random-port}
        sshOpts='-p '$port' -oUserKnownHostsFile=${known_hosts} -i ./ssh_testkey_1' ; ssh='${pkgs.openssh}/bin/ssh root@127.0.0.1 '"$sshOpts"

        install=( ${scripts} install-system ./system.img --no-inspect )
        if [[ ''${args[debug]:-} ]] ; then ''${install[@]} --debug || exit ; else ''${install[@]} --quiet || exit ; fi
        qemu=$( ${scripts} run-qemu --dry-run --efi --efi-vars=$( realpath ./efi-vars.img ) --nat-fw=127.0.0.1:$port-:22 -- $( realpath ./system.img ) )

        ${lib.concatMapStringsSep "\n" ({ pre, test, }: ''
            ${log "(re-)booting: ${system'.config.networking.hostName}"}
            pid= ; ''${qemu[@]} 1>/dev/null & pid=$!
            for i in $(seq 5) ; do sleep 1 ; if $ssh -- true &>/dev/null ; then break ; fi ; done # this fails (loops) only before the VM is created, then it blocks until sshd is up
            if [[ ! -e /proc/$pid ]] ; then echo "The VM process is dead. Was TCP port $port free?" 1>&2 ; exit 1 ; fi

            ok=0 ; ssh=$ssh sshOpts=$sshOpts ${pre} || ok=$? ; if [[ $ok != 0 ]] ; then kill -- $pid || true ; exit $ok ; fi
            ok=0 ; $ssh -- "${test} && poweroff" || ok=$?

            if [[ $ok == 255 || $ok == 0 ]] ; then ok=0 ; else
                echo "!!!!!!!!!!!!!!!!!!!!!!! test failed with $ok, killing qemu ($pid) !!!!!!!!!!!!!!!!!!!!!!!"
                if [[ ''${args[keep-running]:-} ]] ; then wait $pid ; else kill -- $pid || true ; fi
            fi ; wait $pid ; if [[ $ok != 0 ]] ; then exit $ok ; fi
        '') tests'}
        ${log "trashing VM: ${system'.config.networking.hostName}"}
    )'';

    bash-random-port = ''$(
        read lower upper </proc/sys/net/ipv4/ip_local_port_range ; while true ; do
            port=$(( lower + RANDOM % (upper - lower) ))
            if ! ( exec 2>&- ; echo >/dev/tcp/127.0.0.1/$port ) ; then break ; fi
        done ; echo $port
    )'';

}
