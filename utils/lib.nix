let self = rec {
    ## Library Functions

	# Given a function and a list, calls the function for each list element, and returns the merge of all attr sets returned by the function
    # attrs = mapMerge (value: { "${newKey}" = newValue; }) list
    # attrs = mapMerge (key: value: { "${newKey}" = newValue; }) attrs
    mapMerge = toAttr: listOrAttrs: mergeAttrs (if builtins.isAttrs listOrAttrs then lib.mapAttrsToList toAttr listOrAttrs else map toAttr listOrAttrs);

    # Given a list of attribute sets, returns the merged set of all contained attributes, with those in elements with higher indices taking precedence.
    mergeAttrs = attrsList: builtins.foldl' (a: b: a // b) { } attrsList;
    mergeAttrsRecursive = attrsList: let # slightly adjusted from https://stackoverflow.com/a/54505212
        merge = attrPath: lib.zipAttrsWith (name: values:
            if builtins.length values == 1
                then builtins.head values
            else if builtins.all builtins.isList values
                then lib.unique (builtins.concatLists values)
            else if builtins.all builtins.isAttrs values
                then merge (attrPath ++ [ name ]) values
            else builtins.elemAt values (builtins.length values - 1)
        );
    in merge [ ] attrsList;

    # Given a regular expression with capture groups and a list of strings, returns the flattened list of all the matched capture groups of the strings matched in their entirety by the regular expression.
    mapMatching = exp: strings: (builtins.filter (v: v != null) (builtins.concatLists (builtins.filter (v: v != null) (map (string: (builtins.match exp string)) strings))));
    # Given a regular expression and a list of strings, returns the list of all the strings matched in their entirety by the regular expression.
    filterMatching = exp: strings: (builtins.filter (matches exp) strings);
    matches = exp: string: builtins.match exp string != null;
    extractChars = exp: string: let match = (builtins.match "^.*(${exp}).*$" string); in if match == null then null else builtins.head match;

    # If »exp« (which mustn't match across »\n«) matches (a part of) exactly one line in »text«, return that »line« including tailing »\n«, plus the text part »before« and »after«, and the text »without« the line.
    extractLine = exp: text: let split = builtins.split "([^\n]*${exp}[^\n]*\n)" (builtins.unsafeDiscardStringContext text); get = builtins.elemAt split; ctxify = str: lib.addContextFrom text str; in if builtins.length split != 3 then null else rec { before = ctxify (get 0); line = ctxify (builtins.head (get 1)); after = ctxify (get 2); without = ctxify (before + after); }; # (TODO: The string context stuff is actually required, but why? Shouldn't »builtins.split« propagate the context?)

	# Given a message and any value, traces both the message and the value, and returns the value.
    trace = lib: message: value: (builtins.trace (message +": "+ (lib.generators.toPretty { } value)) value);

    pathToName = path: (builtins.replaceStrings [ "/" ":" ] [ "-" "-" ] path);
    # (If »path« ends with »/«, then »path[0:-1]« is the closest "parent".)
    parentPaths = path: let parent = builtins.dirOf path; in if parent == "." || parent == "/" then [ ] else (parentPaths parent) ++ [ parent ];

	# Given a string, returns its first/last char (or last utf-8(?) byte?).
    firstChar = string: builtins.substring                                (0) 1 string;
    lastChar  = string: builtins.substring (builtins.stringLength string - 1) 1 string;

    startsWith = prefix: string: let length = builtins.stringLength prefix; in (builtins.substring                                     (0) (length) string) == prefix;
    endsWith   = suffix: string: let length = builtins.stringLength suffix; in (builtins.substring (builtins.stringLength string - length) (length) string) == suffix;

    getListAttr = name: attrs: if attrs != null then ((attrs."${name}s" or [ ]) ++ (if attrs?${name} then [ attrs.${name} ] else [ ])) else [ ];

    removeTailingNewline = string: if lastChar string == "\n" then builtins.substring 0 (builtins.stringLength string - 1) string else string;

    pow = (let pow = b: e: if e == 1 then b else if e == 0 then 1 else b * pow b (e - 1); in pow); # (how is this not an operator or builtin?)

    # TODO: remove:
    bitwiseAnd = builtins.bitAnd; #bitwiseOp (a: b: if a + b == 2 then 1 else 0); # (currently the only one that works, since the MSB of the shorter number are discarded)
    #bitwiseOp = op: a: b: lib.fold (a: b: a + b) 0 (imap0 (i: b: if b == 0 then 0 else pow 2 i) (lib.zipListsWith op (lib.reverseList (lib.toBaseDigits 2 a)) (reverseList (lib.toBaseDigits 2 b))));

    toBinString = int: builtins.concatStringsSep "" (map builtins.toString (lib.toBaseDigits 2 int));

    notNull = value: value != null;

    ifNull      = value: default: (if value == null then default else value);
    withDefault = default: value: (if value == null then default else value);
    passNull = mayNull: expression: (if mayNull == null then null else expression);

    repeat = count: element: builtins.genList (i: element) count;

    rpoolOf = hostName: "rpool-${builtins.substring 0 8 (builtins.hashString "sha256" hostName)}";

    ## Turns an attr set into a bash dictionary (associative array) declaration, e.g.:
    #  bashSnippet = "declare -A dict=(\n${asBashDict { } { foo = "42"; bar = "baz"; }}\n)"
    asBashDict = { mkName ? (n: v: n), mkValue ? (n: v: v), indent ? "    ", ... }: attrs: (
        builtins.concatStringsSep "\n" (lib.mapAttrsToList (name: value: (
            "${indent}[${lib.escapeShellArg (mkName name value)}]=${lib.escapeShellArg (mkValue name value)}"
        )) attrs)
    );

    ## Used as a »system.activationScripts« snippet, this performs substitutions on a »text« before writing it to »path«.
    #  For each name-value pair in »substitutes«, all verbatim occurrences of the attribute name in »text« are replaced by the content of the file with path of the attribute value.
    #  Since this happens one by one in no defined order, the attribute values should be chosen such that they don't appear in any of the files that are substituted in.
    #  If a file that is supposed to be substituted in is missing, then »placeholder« is inserted instead, and the activation snipped reports a failure.
    #  If »enable« is false, then the file at »path« is »rm«ed instead.
    writeSubstitutedFile = { enable ? true, path, text, substitutes, placeholder ? "", perms ? "440", owner ? "root", group ? "root", }: let
        hash = builtins.hashString "sha256" text;
        esc = lib.escapeShellArg;
    in { "write ${path}" = if enable then ''
        text=$(cat << '#${hash}'
        ${text}
        #${hash}
        )
        ${builtins.concatStringsSep "\n" (lib.mapAttrsToList (name: file: "text=\"\${text//${esc name}/$( if ! cat ${esc file} ; then printf %s ${esc placeholder} ; false ; fi )}\"") substitutes)}
        install -m ${esc (toString perms)} -o ${esc (toString owner)} -g ${esc (toString group)} /dev/null ${esc path}
        <<<"$text" cat    >${esc path}
    '' else ''rm ${esc path} || true''; };

    # Return a list of the absolute paths of all folders and ».nix« or ».nix.md« files in »dir« whose names are not in »except«.
    getNixFiles = dir: except: let listing = builtins.readDir dir; in (builtins.filter (e: e != null) (map (name: (
        if !(builtins.elem name except) && (listing.${name} == "directory" || (builtins.match ''.*[.]nix([.]md)?$'' name) != null) then "${dir}/${name}" else null
    )) (builtins.attrNames listing)));

    # Builds an attrset that, for each folder that contains a »default.nix«, and for each ».nix« or ».nix.md« file in »dir« (other than those whose names are in »except«), maps the the name of that folder, or the name of the file without extension(s), to its full path.
    getNamedNixFiles = dir: except: let listing = builtins.readDir dir; in mapMerge (name: if !(builtins.elem name except) then (
        if (listing.${name} == "directory" && builtins.pathExists "${dir}/${name}/default.nix") then { ${name} = "${dir}/${name}"; } else let
            match = builtins.match ''^(.*)[.]nix([.]md)?$'' name;
        in if (match != null) then { ${builtins.head match} = "${dir}/${name}"; } else { }
    ) else { }) (builtins.attrNames listing);

    ## Decides whether a thing is probably a NixOS configuration module or not.
    #  Probably because almost everything could be a module declaration (any attribute set or function returning one is potentially a module).
    #  Per convention, modules (at least those declared stand-alone in a file) are declared as functions taking at least the named arguments »config«, »pkgs«, and »lib«. Once entered into the module system, to remember where they came from, modules get wrapped in an attrset »{ _file = "<path>"; imports = [ <actual_module> ]; }«.
    isProbablyModule = thing: let args = builtins.functionArgs thing; in (
        (builtins.isFunction thing) && (builtins.isAttrs (thing args)) && (builtins.isBool (args.config or null)) && (builtins.isBool (args.lib or null)) && (builtins.isBool (args.pkgs or null))
    ) || (
        (builtins.isAttrs thing) && ((builtins.attrNames thing) == [ "_file" "imports" ]) && ((builtins.isString thing._file) || (builtins.isPath thing._file)) && (builtins.isList thing.imports)
    );

    ## Decides whether a thing could be a NixPkgs overlay.
    #  Any function with two (usually unnamed) arguments returning an attrset could be an overlay, so that's rather vague.
    couldBeOverlay = thing: let result1 = thing (builtins.functionArgs thing);  result2 = result1 (builtins.functionArgs result1); in builtins.isFunction thing && builtins.isFunction result1 && builtins.isAttrs result2;

    # Builds an attrset that, for each folder or ».nix« or ».nix.md« file (other than »default.nix«) in this folder, as the name of that folder or the name of the file without extension(s), exports the result of importing that file/folder.
    importAll = dir: builtins.mapAttrs (name: path: import path) (getNamedNixFiles dir [ "default.nix" ]);

    ## Returns an attrset that, for each file in »dir« (except »default.nix« and as filtered and named by »getNamedNixFiles dir except«), imports that file and exposes only if the result passes »filter«. If provided, the imported value is »wrapped« after filtering.
    #  If a file/folder' import that is rejected by »filter« is an attrset (for example because it results from a call to this function), then all attributes whose values pass »filter« are prefixed with the file/folders name plus a slash and merged into the overall attrset.
    #  Example: Given a file tree like this, where each »default.nix« contains only a call to this function with the containing directory as »dir«, and every other file contains a definition of something accepted by the »filter«:
    #     ├── default.nix
    #     ├── a.nix.md
    #     ├── b.nix
    #     └── c
    #         ├── default.nix
    #         ├── d.nix
    #         └── e.nix.md
    # The top level »default.nix« returns:
    # { "a" = <filtered>; "b" = <filtered>; "c/d" = <filtered>; "c/e" = <filtered>; }
    importFilteredFlattened = dir: { except ? [ ], filter ? (thing: true), wrap ? (path: thing: thing), }: let
        files = getNamedNixFiles dir (except ++ [ "default.nix" ]);
    in mapMerge (name: path: let
        thing = import path;
    in if (filter thing) then (
        { ${name} = wrap path thing; }
    ) else (if (builtins.isAttrs thing) then (
        mapMerge (name': thing': if (filter thing') then (
            { "${name}/${name'}" = thing'; }
        ) else { "${name}/${name'}" = "nope"; }) thing
    ) else { ${name} = "nope"; })) files;

    # Used in a »default.nix« and called with the »dir« it is in, imports all modules in that directory as attribute set. See »importFilteredFlattened« and »isProbablyModule« for details.
    importModules = dir: opts: importFilteredFlattened dir (opts // { filter = isProbablyModule; wrap = path: module: { _file = path; imports = [ module ]; }; });

    # Used in a »default.nix« and called with the »dir« it is in, imports all overlays in that directory as attribute set. See »importFilteredFlattened« and »couldBeOverlay« for details.
    importOverlays = dir: opts: importFilteredFlattened dir (opts // { filter = couldBeOverlay; });

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
    in outputs (builtins.mapAttrs (name: input: if patches?${name} && patches.${name} != [ ] then (let
        patched = applyPatches {
            name = "${name}-patched"; src = input;
            patches = map (patch: if patch ? url then fetchpatch patch else patch) patches.${name};
        };
    in (
        if input?inputs then (let self = (import "${patched.outPath}/flake.nix").outputs ({ inherit self; } // input.inputs); in patched // self) else patched
    )) else input) inputs);

    # TODO: documentation
    getSystemPreface = cfgPath: args: let # Given a path to a host config file, returns some properties defined in its first inline module (to be used where accessing them via »nodes.${name}.config...« isn't possible).
        imported = (import cfgPath) ({ inputs = null; config = null; pkgs = null; lib = null; name = null; nodes = null; } // args);
        module = builtins.elemAt imported.imports 0; props = module.preface;
    in if (
        imported?imports && (builtins.isList imported.imports) && (imported.imports != [ ]) && module?preface && props?hardware
    ) then (props) else throw "File ${cfgPath} must fulfill the structure: { ... }: { imports = [ { preface = { hardware = str; ... } } ]; }";

    /**
     * Builds the System Configuration for a single host. Since each host depends on the context of all other host (in the same "network"), this is essentially only callable through »mkNixosConfigurations« above.
     */
    mkNixosConfiguration = args@{ name, entryPath, peers, importPkgs, modules ? [ ], nixosSystem ? args.specialArgs.lib.nixosSystem, ... }: let
        preface = (getSystemPreface entryPath specialArgs);
        crossSystem = preface.hardware; localSystem = args.localSystem or crossSystem;
        pkgs = (importPkgs { system = localSystem; }); inherit (pkgs) lib;
        specialArgs = { # make these available in the attrSet passed to the modules
            inherit pkgs lib;
        } // (args.specialArgs or { }) // {
            inherit name; nodes = peers; # NixOPS
        };
    in { inherit entryPath preface; } // (nixosSystem {
        system = crossSystem;
        modules = [ (
            entryPath # (if not imported by path, errors in this would be reported here)
        ) {
            # The system architecture (often referred to as »system«).
            options.preface.hardware = lib.mkOption { type = lib.types.str; readOnly = true; };
        } {
            # List of host names to instantiate this host config for, instead of just for the file name.
            options.preface.instances = lib.mkOption { type = lib.types.listOf lib.types.str; default = [ name ]; };
        } ({ config, ... }: {

            imports = modules; nixpkgs = { inherit pkgs; };

            networking.hostName = name;

            system.extraSystemBuilderCmds = if !config.boot.initrd.enable then "" else ''
                ln -sT ${config.system.build.bootStage1} $out/boot-stage-1.sh # (this is super annoying to locate otherwise)
            '';

        }) ] ++ (args.extraModules or [ ]);
        specialArgs = builtins.removeAttrs specialArgs [ "pkgs" ]; # explicitly passing »pkgs« here breaks »nixpkgs.overlays« (but the same value is still passed as »nixpkgs.pkgs«)
    });

    /**
     * Given either a list (or attr set) of »files« (paths to ».nix« or ».nix.md« files for dirs with »default.nix« files in them) or a »dir« path (and optionally a list of file names to »exclude« from it), this builds the NixOS configuration for each host (per file) in the context of all configs provided.
     * If »files« is an attr set, exactly one host with the attribute's name as hostname is built for each attribute. Otherwise the default is to build for one host per configuration file, named as the file name without extension or the sub-directory name. Setting »preface.instances« can override this to build the same configuration for those multiple names instead (the specific »name« is passed as additional argument to the modules and can thus be used to adjust the config per instance).
     * If »localSystem« is provided, then cross compilation is enabled for all hosts whose target architecture is different from it. Since cross compilation currently fails for (some stuff in) NixOS, better don't set »localSystem«. Without it, building for other platforms works fine (just slowly) if »boot.binfmt.emulatedSystems« is configured on the building system for the respective target(s).
     */
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

    # TODO: documentation
    mkSystemsFalke = args@{ systems, importPkgs, specialArgs ? { }, modules ? [ ], scripts ? [ ], inputs ? { }, configPath ? null, }: let
        otherArgs = builtins.removeAttrs args [ "systems" ];
        nixosConfigurations = if builtins.isList systems then mergeAttrs (map (systems: mkNixosConfigurations (otherArgs // systems)) systems) else mkNixosConfigurations (otherArgs // systems);
    in {
        inherit nixosConfigurations;
    } // (if scripts == [ ] then { } else forEachSystem [ "aarch64-linux" "x86_64-linux" ] (localSystem: let
        pkgs = (importPkgs { system = localSystem; }); inherit (pkgs) lib;
        nix_wrapped = pkgs.writeShellScriptBin "nix" ''exec ${pkgs.nix}/bin/nix --extra-experimental-features nix-command "$@"'';
    in {

        # E.g.: $ nix run .#$target -- install-system /tmp/system-$target.img
        # E.g.: $ nix run /etc/nixos/#$(hostname) -- sudo
        # If the first argument (after  »--«) is »sudo«, then the program will re-execute itself with sudo as root (minus the first »sudo« argument).
        # If the first/next argument is »bash«, it will execute an interactive shell with the variables and functions sourced (largely equivalent to »nix develop .#$host«).
        apps = lib.mapAttrs (name: system: let
            targetSystem = system.config.preface.hardware;
            appliedScripts = map (src: (withPkgs pkgs).substituteLazy { inherit src; ctx = system; }) scripts;

        in { type = "app"; program = "${pkgs.writeShellScript "scripts-${name}" ''

            # if first arg is »sudo«, re-execute this script with sudo (as root)
            if [[ $1 == sudo ]] ; then shift ; exec sudo --preserve-env=SSH_AUTH_SOCK,debug -- "$0" "$@" ; fi

            # provide installer tools (native to localSystem, not targetSystem)
            PATH=${pkgs.nixos-install-tools}/bin:${nix_wrapped}/bin:${pkgs.nix}/bin:$PATH

            # if the (now) first arg is »bash« or there are no args, re-execute this script as bash »--init-file«, starting an interactive bash in the context of the script
            if [[ $1 == bash || $# == 0 ]] ; then
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

            ${lib.concatMapStringsSep "\n" (script: "source ${script}") appliedScripts}

            # either call »$1« with the remaining parameters as arguments, or if »$1« is »-c« eval »$2«.
            set -eu ; if [[ $1 == -x ]] ; then shift ; set -x ; fi
            if [[ $1 == -c ]] ; then eval "$2" ; else "$@" ; fi
        ''}"; }) nixosConfigurations;


        # E.g.: $ nix develop /etc/nixos/#$(hostname)
        # ... and then call any of the functions in ./utils/functions.sh (in the context of »$(hostname)«, where applicable).
        # To get an equivalent root shell: $ nix run /etc/nixos/#functions-$(hostname) -- sudo bash
        devShells = lib.mapAttrs (name: system: pkgs.mkShell (let
            appliedScripts = map (src: (withPkgs pkgs).substituteLazy { inherit src; ctx = system; }) scripts;
        in {
            nativeBuildInputs = [ pkgs.nixos-install-tools nix_wrapped pkgs.nix ];
            shellHook = ''
                ${lib.concatMapStringsSep "\n" (script: "source ${script}") appliedScripts}
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

    # Given a list of »overlays« and »pkgs« with them applied, returns the subset of »pkgs« that was directly modified by the overlays.
    getModifiedPackages = pkgs: overlays: let
        names = builtins.concatLists (map (overlay: builtins.attrNames (overlay { } { })) (builtins.attrValues overlays));
    in mapMerge (name: { ${name} = pkgs.${name}; }) names;

    ## Library functions that need access to »pkgs« (not sure whether this is a nice way of implementing that):
    withPkgs = pkgs: {

        # Wraps a (bash) script into a "package", making »deps« available on the script's path.
        wrap-script = path: opts: deps: let
            name = opts.name or (builtins.baseNameOf (builtins.unsafeDiscardStringContext "${path}"));
        in pkgs.runCommandLocal name {
            script = path; nativeBuildInputs = [ pkgs.makeWrapper ];
        } ''makeWrapper $script $out/bin/${name} --prefix PATH : ${lib.makeBinPath deps}'';

        ## Creates a package for `config.systemd.packages` that adds an `override.conf` to the specified `unit` (which is the only way to modify a single service template instance).
        mkSystemdOverride = unit: text: (pkgs.runCommandNoCC unit { preferLocalBuild = true; allowSubstitutes = false; } ''
            mkdir -p $out/${lib.escapeShellArg "/etc/systemd/system/${unit}.d/"}
            <<<${lib.escapeShellArg text} cat >$out/${lib.escapeShellArg "/etc/systemd/system/${unit}.d/override.conf"}
        '');

        substituteLazy = { src, ctx, }: let
            script = builtins.readFile src; name = builtins.baseNameOf "${src}";
            split = builtins.split ''@\{([a-zA-Z][a-zA-Z0-9_.-]*[a-zA-Z0-9](![a-zA-Z0-9]+)?)([:*@\[#%/^,\}])'' script; # (first part of a bash parameter expansion, with »@« instead of »$«)
            decls = lib.unique (map builtins.head (builtins.filter builtins.isList split));
            vars = pkgs.writeText "${name}-vars" (lib.concatMapStringsSep "\n" (decl: let
                call = let split = builtins.split "!" decl; in if (builtins.length split) == 1 then null else builtins.elemAt split 2;
                path = (builtins.filter builtins.isString (builtins.split "[.]" (if call == null then decl else builtins.substring 0 ((builtins.stringLength decl) - (builtins.stringLength call) - 1) decl)));
                value'' = lib.attrByPath path null ctx; value' = if call == null || value'' == null then value'' else builtins.${call} value''; value = if (
                    (builtins.isBool value') || (builtins.isFloat value') || (builtins.isInt value') || (builtins.isPath value')
                ) then builtins.toString value' else value';
                name = (builtins.concatStringsSep "_" path) + (if call == null then "" else "__${call}");
            in (
                     if (value == null) then ""
                else if (builtins.isString value) then "${name}=${lib.escapeShellArg value}"
                else if (builtins.isList value) then "${name}=(${lib.escapeShellArgs (map builtins.toString value)})"
                else if (builtins.isAttrs value) then "declare -A ${name}=${"(\n${asBashDict { mkValue = name: builtins.toString; } value}\n)"}"
                else throw "Can't use value of unsupported type ${builtins.typeOf} as substitution for ${decl}" # builtins.isFunction
            )) decls);
        in pkgs.writeShellScript name ''
            source ${vars}
            ${lib.concatMapStringsSep "" (seg: if builtins.isString seg then seg else (
                "$"+"{"+(builtins.replaceStrings [ "." "!" ] [ "_" "__" ] (builtins.head seg))+(builtins.elemAt seg 2)
            )) split}
        '';
    };

    ## Simplifies a path (or any other string) such that it can be used as a systemd unit name.
    escapeUnitName = name: lib.concatMapStringsSep "" (s: if builtins.isList s then "-" else s) (builtins.split "[^a-zA-Z0-9_.\\-]+" name); # from nixos/modules/services/backup/syncoid.nix

    # Given »from« and »to« as »config.my.network.spec.hosts.*«,
    # picks the first of »to«'s IPs whose required subnet is either empty/any, or a prefix to any of the subnets in »from«:
    # ip = preferredRoute self.subNets other.routes;
    # ip6 = preferredRoute self.subNets (builtins.filter (r: r.is6) other.routes);
    # to.find(({ ip, prefix }) => from.any(_=>_.startsWith(prefix))).ip
    preferredRoute = from: to: (lib.findFirst ({ prefix, ip, ... }: prefix == "" || (builtins.any (fromSub: startsWith prefix fromSub) from)) { ip = ""; } to).ip;

    # Given »config.ids« (or equivalent) and a user name, returns the users numeric »uid:gid« pair as string.
    getOwnership = { gids, uids, ... }: user: "${toString uids.${user}}:${toString gids.${user}}";

}; lib = let ## Stuff taken from »pkgs.lib« to remove the dependency on it:
    inherit (builtins) attrNames catAttrs concatMap concatStringsSep elem elemAt filter foldl' genList head length listToAttrs min replaceStrings substring tail;
in rec {
    addContextFrom = a: b: substring 0 0 a + b;
    attrByPath = attrPath: default: e: let attr = head attrPath; in if attrPath == [] then e else if e ? ${attr} then attrByPath (tail attrPath) default e.${attr} else default;
    concatMapStringsSep = sep: f: list: concatStringsSep sep (map f list);
    escapeShellArg = arg: "'${replaceStrings ["'"] ["'\\''"] (toString arg)}'";
    escapeShellArgs = concatMapStringsSep " " escapeShellArg;
    filterAttrs = pred: set: listToAttrs (concatMap (name: let v = set.${name}; in if pred name v then [(nameValuePair name v)] else []) (attrNames set));
    findFirst = pred: default: list: let found = filter pred list; in if found == [] then default else head found;
    getOutput = output: pkg: if ! pkg ? outputSpecified || ! pkg.outputSpecified then pkg.${output} or pkg.out or pkg else pkg;
    imap0 = f: list: genList (n: f n (elemAt list n)) (length list);
    mapAttrsToList = f: attrs: map (name: f name attrs.${name}) (attrNames attrs);
    makeBinPath = makeSearchPathOutput "bin" "bin";
    makeSearchPath = subDir: paths: concatStringsSep ":" (map (path: path + "/" + subDir) (filter (x: x != null) paths));
    makeSearchPathOutput = output: subDir: pkgs: makeSearchPath subDir (map (getOutput output) pkgs);
    nameValuePair = name: value: { inherit name value; };
    reverseList = xs: let l = length xs; in genList (n: elemAt xs (l - n - 1)) l;
    toBaseDigits = base: i: let go = i: if i < base then [i] else let r = i - ((i / base) * base); q = (i - r) / base; in [r] ++ go q; in assert (base >= 2); assert (i >= 0); reverseList (go i);
    unique = foldl' (acc: e: if elem e acc then acc else acc ++ [ e ]) [];
    zipAttrsWith = builtins.zipAttrsWith or (f: sets: zipAttrsWithNames (concatMap attrNames sets) f sets);
    zipAttrsWithNames = names: f: sets: listToAttrs (map (name: { inherit name; value = f name (catAttrs name sets); }) names);
    zipListsWith = f: fst: snd: genList (n: f (elemAt fst n) (elemAt snd n)) (min (length fst) (length snd));
}; in self
