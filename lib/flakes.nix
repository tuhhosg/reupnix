dirname: inputs@{ self, nixpkgs, ...}: let
    inherit (nixpkgs) lib;
    inherit (import "${dirname}/vars.nix"    dirname inputs) mapMerge mergeAttrs;
    inherit (import "${dirname}/imports.nix" dirname inputs) getModifiedPackages getNixFiles importWrapped;
    inherit (import "${dirname}/scripts.nix" dirname inputs) substituteLazy;
in rec {

    # Simplified implementation of »flake-utils.lib.eachSystem«.
    forEachSystem = systems: do: flipNames (mapMerge (arch: { ${arch} = do arch; }) systems);

    # Given an attribute set of attribute sets (»{ ${l1name}.${l2name} = value; }«), flips the positions of the first and second name level, producing »{ ${l3name}.${l1name} = value; }«. The set of »l2name«s does not need to be the same for each »l1name«.
    flipNames = attrs: let
        l1names = builtins.attrNames attrs;
        l2names = builtins.concatMap builtins.attrNames (builtins.attrValues attrs);
    in mapMerge (l2name: {
        ${l2name} = mapMerge (l1name: if attrs.${l1name}?${l2name} then { ${l1name} = attrs.${l1name}.${l2name}; } else { }) l1names;
    }) l2names;

    # Sooner or later this should be implemented in nix itself, for now require »inputs.nixpkgs« and a system that can run »x86_64-linux« (native or through qemu).
    patchFlakeInputs = inputs: patches: outputs: let
        inherit ((import inputs.nixpkgs { system = "x86_64-linux"; }).pkgs) applyPatches fetchpatch;
    in outputs (builtins.mapAttrs (name: input: if name != "self" && patches?${name} && patches.${name} != [ ] then (let
        patched = applyPatches {
            name = "${name}-patched"; src = input;
            patches = map (patch: if patch ? url then fetchpatch patch else patch) patches.${name};
        };
    in (
        if input?inputs then (let self = (import "${patched.outPath}/flake.nix").outputs ({ inherit self; } // input.inputs); in patched // self) else patched
    )) else input) inputs);

    # Generates implicit flake outputs by importing conventional paths in the local repo.
    importRepo = inputs: repoPath: outputs: (outputs inputs ((if builtins.pathExists "${repoPath}/lib/default.nix" then {
        lib           = import "${repoPath}/lib"      "${repoPath}/lib"      inputs;
    } else { }) // (if builtins.pathExists "${repoPath}/overlays/default.nix" then rec {
        overlays      = import "${repoPath}/overlays" "${repoPath}/overlays" inputs;
        overlay       = final: prev: builtins.foldl' (prev: overlay: overlay final prev) prev (builtins.attrValues overlays); # (I think this should work)
    } else { }) // (if builtins.pathExists "${repoPath}/modules/default.nix" then rec {
        nixosModules  = import "${repoPath}/modules"  "${repoPath}/modules"  inputs;
        nixosModule   = { imports = builtins.attrValues nixosModules; };
    } else { })));

    # Combines »patchFlakeInputs« and »importRepo« in a single call.
    patchFlakeInputsAndImportRepo = inputs: patches: repoPath: outputs: (
        patchFlakeInputs inputs patches (inputs: importRepo inputs repoPath outputs)
    );

    # Given a path to a host config file, returns some properties defined in its first inline module (to be used where accessing them via »nodes.${name}.config...« isn't possible).
    getSystemPreface = entryPath: args: let
        imported = (importWrapped inputs entryPath) ({ config = null; pkgs = null; lib = null; name = null; nodes = null; } // args);
        module = builtins.elemAt imported.imports 0; props = module.preface;
    in if (
        imported?imports && (builtins.isList imported.imports) && (imported.imports != [ ]) && module?preface && props?hardware
    ) then (props) else throw "File ${entryPath} must fulfill the structure: dirname: inputs: { ... }: { imports = [ { preface = { hardware = str; ... } } ]; }";

    # Builds the System Configuration for a single host. Since each host depends on the context of all other host (in the same "network"), this is essentially only callable through »mkNixosConfigurations«.
    # See »mkSystemsFalke« for documentation of the arguments.
    mkNixosConfiguration = args@{ name, entryPath, peers, inputs, overlays, modules, nixosSystem, localSystem ? null, ... }: let
        preface = (getSystemPreface entryPath ({ inherit lib; } // specialArgs));
        targetSystem = "${preface.hardware}-linux"; buildSystem = if localSystem != null then localSystem else targetSystem;
        specialArgs = (args.specialArgs or { }) // { # make these available in the attrSet passed to the modules
            inherit name; nodes = peers; # NixOPS
        };
    in { inherit preface; } // (nixosSystem {
        system = targetSystem;
        modules = [ (
            { _file = entryPath; imports = [ (importWrapped inputs entryPath) ]; } # (preserve the location of reported errors)
        ) {
            # The system architecture (often referred to as »system«).
            options.preface.hardware = lib.mkOption { type = lib.types.str; readOnly = true; };
        } {
            # List of host names to instantiate this host config for, instead of just for the file name.
            options.preface.instances = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ name ]; };
        } ({ config, ... }: {

            imports = modules; nixpkgs = { inherit overlays; }
            // (if buildSystem != targetSystem then { localSystem.system = buildSystem; crossSystem.system = targetSystem; } else { system = targetSystem; });

            networking.hostName = name;

            system.extraSystemBuilderCmds = if !config.boot.initrd.enable then "" else ''
                ln -sT ${builtins.unsafeDiscardStringContext config.system.build.bootStage1} $out/boot-stage-1.sh # (this is super annoying to locate otherwise)
            '';

        }) ];
        specialArgs = specialArgs; # explicitly passing »pkgs« here breaks »config.nixpkgs.overlays«!
    });

    # Given either a list (or attr set) of »files« (paths to ».nix« or ».nix.md« files for dirs with »default.nix« files in them) or a »dir« path (and optionally a list of file names to »exclude« from it), this builds the NixOS configuration for each host (per file) in the context of all configs provided.
    # If »files« is an attr set, exactly one host with the attribute's name as hostname is built for each attribute. Otherwise the default is to build for one host per configuration file, named as the file name without extension or the sub-directory name. Setting »preface.instances« can override this to build the same configuration for those multiple names instead (the specific »name« is passed as additional »specialArgs« to the modules and can thus be used to adjust the config per instance).
    # All other arguments are as specified by »mkSystemsFalke« and are passed to »mkNixosConfiguration«.
    mkNixosConfigurations = args: let # { files, dir, exclude, ... }
        files = args.files or (getNixFiles args.dir (args.exclude or [ ]));
        files' = if builtins.isAttrs files then files else (builtins.listToAttrs (map (entryPath: let
            stripped = builtins.match ''^(.*)[.]nix[.]md$'' (builtins.baseNameOf entryPath);
            name = if stripped != null then (builtins.elemAt stripped 0) else (builtins.baseNameOf entryPath);
        in { inherit name; value = entryPath; }) files));

        configs = mapMerge (name: entryPath: (let
            preface = (getSystemPreface entryPath { });
        in (mapMerge (name: {
            "${name}" = mkNixosConfiguration ((
                builtins.removeAttrs args [ "files" "dir" "exclude" ]
            ) // {
                inherit name entryPath; peers = configs;
            });
        }) (if !(builtins.isAttrs files) && preface?instances then preface.instances else [ name ])))) (files');

        withId = lib.filterAttrs (name: node: node.preface?id) configs;
        ids = mapMerge (name: node: { "${toString node.preface.id}" = name; }) withId;
        duplicate = builtins.removeAttrs withId (builtins.attrValues ids);
    in if duplicate != { } then (
        throw "»my.system.id«s are not unique! The following hosts share their IDs with some other host: ${builtins.concatStringsSep ", " (builtins.attrNames duplicate)}"
    ) else configs;

    # Builds a system of NixOS hosts and exports them plus managing functions as flake outputs.
    # All arguments are optional, as long as the default can be derived from the other arguments as passed.
    mkSystemsFalke = args@{
        # Arguments »{ files, dir, exclude, }« to »mkNixosConfigurations«, see there for details. May also be a list of those attrsets, in which case those multiple sets of hosts will be built separately by »mkNixosConfigurations«, allowing for separate sets of »peers« passed to »mkNixosConfiguration«. Each call will receive all other arguments, and the resulting sets of hosts will be merged.
        systems ? ({ dir = "${configPath}/hosts/"; exclude = [ ]; }),
        # List of overlays to set as »config.nixpkgs.overlays«. Defaults to the ».overlay(s)« of all »inputs« (incl. »inputs.self«).
        overlays ? (builtins.concatLists (map (input: if input?overlay then [ input.overlay ] else if input?overlays then builtins.attrValues input.overlays else [ ]) (builtins.attrValues inputs))),
        # List of Modules to import for all hosts, in addition to the default ones in »nixpkgs«. The host-individual module should selectively enable these. Defaults to all »inputs«' ».nixosModule(s)« (including »inputs.self.nixosModule(s)«).
        modules ? (map (input: input.nixosModule or (if input?nixosModules then { imports = builtins.attrValues input.nixosModules; } else { })) (builtins.attrValues (builtins.removeAttrs inputs [ "nixpkgs" ]))),
        # Additional arguments passed to each module evaluated for the host config (if that module is defined as a function).
        specialArgs ? { },
        # List of bash scripts defining functions that do installation and maintenance operations. See »apps« below for more information.
        scripts ? [ ],
        # An attrset of imported Nix flakes, for example the argument(s) passed to the flake »outputs« function. All other arguments are optional (and have reasonable defaults) if this is provided and contains »self« and the standard »nixpkgs«. This is also the second argument passed to the individual host's top level config files.
        inputs ? { },
        # Root path of the NixOS configuration. »./.« in the »flake.nix«
        configPath ? inputs.self.outPath,
        # The function of that name as defined in »nixpkgs/flake.nix«, or equivalent.
        nixosSystem ? lib.attrByPath [ "lib" "nixosSystem" ] inputs.nixpkgs.lib.nixosSystem specialArgs,
        # If provided, then cross compilation is enabled for all hosts whose target architecture is different from this. Since cross compilation currently fails for (some stuff in) NixOS, better don't set »localSystem«. Without it, building for other platforms works fine (just slowly) if »boot.binfmt.emulatedSystems« is configured on the building system for the respective target(s).
        localSystem ? null,
    ... }: let
        otherArgs = (builtins.removeAttrs args [ "systems" ]) // { inherit systems overlays modules specialArgs scripts inputs configPath nixosSystem localSystem; };
        nixosConfigurations = if builtins.isList systems then mergeAttrs (map (systems: mkNixosConfigurations (otherArgs // systems)) systems) else mkNixosConfigurations (otherArgs // systems);
    in {
        inherit nixosConfigurations;
    } // (if scripts == [ ] then { } else forEachSystem [ "aarch64-linux" "x86_64-linux" ] (localSystem: let
        pkgs = (import inputs.nixpkgs { inherit overlays; system = localSystem; });
        nix_wrapped = pkgs.writeShellScriptBin "nix" ''exec ${pkgs.nix}/bin/nix --extra-experimental-features nix-command "$@"'';
    in {

        # E.g.: $ nix run .#$target -- install-system /tmp/system-$target.img
        # E.g.: $ nix run /etc/nixos/#$(hostname) -- sudo
        # If the first argument (after  »--«) is »sudo«, then the program will re-execute itself with sudo as root (minus the first »sudo« argument).
        # If the first/next argument is »bash«, it will execute an interactive shell with the variables and functions sourced (largely equivalent to »nix develop .#$host«).
        apps = lib.mapAttrs (name: system: let
            appliedScripts = substituteLazy { inherit pkgs scripts; context = system; };

        in { type = "app"; program = "${pkgs.writeShellScript "scripts-${name}" ''

            # if first arg is »sudo«, re-execute this script with sudo (as root)
            if [[ $1 == sudo ]] ; then shift ; exec sudo --preserve-env=SSH_AUTH_SOCK,debug -- "$0" "$@" ; fi

            # if the (now) first arg is »bash« or there are no args, re-execute this script as bash »--init-file«, starting an interactive bash in the context of the script
            if [[ $1 == bash ]] || [[ $# == 0 && $0 == *-scripts-${name} ]] ; then
                set -x
                exec ${pkgs.bashInteractive}/bin/bash --init-file <(cat << "EOS"${"\n"+''
                    # prefix the script to also include the default init files
                    ! [[ -e /etc/profile ]] || . /etc/profile
                    for file in ~/.bash_profile ~/.bash_login ~/.profile ; do
                        if [[ -r $file ]] ; then . $file ; break ; fi
                    done ; unset $file
                    # add active »hostName« to shell prompt
                    PS1=''${PS1/\\$/\\[\\e[93m\\](${name})\\[\\e[97m\\]\\$}
                ''}EOS
                cat $0) -i
            fi

            # provide installer tools (native to localSystem, not targetSystem)
            PATH=${pkgs.nixos-install-tools}/bin:${nix_wrapped}/bin:${pkgs.nix}/bin:$PATH

            ${appliedScripts}

            # either call »$1« with the remaining parameters as arguments, or if »$1« is »-c« eval »$2«.
            if [[ ''${1:-} == -x ]] ; then shift ; set -x ; fi
            if [[ ''${1:-} == -c ]] ; then eval "$2" ; else "$@" ; fi
        ''}"; }) nixosConfigurations;


        # E.g.: $ nix develop /etc/nixos/#$(hostname)
        # ... and then call any of the functions in ./utils/functions.sh (in the context of »$(hostname)«, where applicable).
        # To get an equivalent root shell: $ nix run /etc/nixos/#functions-$(hostname) -- sudo bash
        devShells = lib.mapAttrs (name: system: pkgs.mkShell (let
            appliedScripts = substituteLazy { inherit pkgs scripts; context = system; };
        in {
            nativeBuildInputs = [ pkgs.nixos-install-tools nix_wrapped pkgs.nix ];
            shellHook = ''
                ${appliedScripts}
                # add active »hostName« to shell prompt
                PS1=''${PS1/\\$/\\[\\e[93m\\](${name})\\[\\e[97m\\]\\$}
            '';
        })) nixosConfigurations;

        packages.all-systems = pkgs.stdenv.mkDerivation { # dummy that just pulls in all system builds
            name = "all-systems"; src = ./.; installPhase = ''
                mkdir -p $out/systems
                ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: system: (
                    "ln -sT ${system.config.system.build.toplevel} $out/systems/${name}"
                )) nixosConfigurations)}
                ${lib.optionalString (inputs != { }) ''
                    mkdir -p $out/inputs
                    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: { outPath, ... }: "ln -sT ${outPath} $out/inputs/${name}") inputs)}
                ''}
                ${lib.optionalString (configPath != null) "ln -sT ${configPath} $out/config"}
            '';
        };

    }));

}
