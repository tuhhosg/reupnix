dirname: { self, nixpkgs, ...}: let
    inherit (nixpkgs) lib;
in rec {

    # Turns an attr set into a bash dictionary (associative array) declaration, e.g.:
    # bashSnippet = "declare -A dict=(\n${asBashDict { } { foo = "42"; bar = "baz"; }}\n)"
    asBashDict = { mkName ? (n: v: n), mkValue ? (n: v: v), indent ? "    ", ... }: attrs: (
        builtins.concatStringsSep "\n" (lib.mapAttrsToList (name: value: (
            "${indent}[${lib.escapeShellArg (mkName name value)}]=${lib.escapeShellArg (mkValue name value)}"
        )) attrs)
    );

    # Turns an attrset into a string that can (safely) be bash-»eval«ed to declare the attributes (prefixed with a »_«) as variables into the current scope.
    asBashEvalSet = recursive: attrs: builtins.concatStringsSep " ; " (lib.mapAttrsToList (name: value: (
        "_${name}=${lib.escapeShellArg (if recursive && builtins.isAttrs value then asBashEvalSet true value else toString value)}"
    )) attrs);

    # Makes an attrset of attrsets eligible to be passed to »asBashDict«. The bash script can (safely) call »eval« on each first-level attribute value to get the second-level attributes (prefixed with a »_«) into the current variable scope.
    # Meant primarily as a helper for »substituteLazy«.
    attrsAsBashEvalSets = attrs: builtins.mapAttrs (name: asBashEvalSet true) attrs;

    # Makes a list of attrsets eligible to be passed to »asBashDict«. The bash script can (safely) call »eval« on each list item to get the contained attributes (prefixed with a »_«) into the current variable scope.
    # Meant primarily as a helper for »substituteLazy«.
    listAsBashEvalSets = list: map (asBashEvalSet true) list;

    # This function allows using nix values in bash scripts without passing an explicit and manually curated list of values to the script.
    # Given a path list of bash script »sources« and an attrset »context«, the function parses the scripts for the literal sequence »@{« followed by a lookup path of period-joined words, resolves that attribute path against »context«, declares a variable with that value and swaps out the »@{« plus path for a »${« use of the declared variable. The returned script sources the variable definitions and all translated »sources« in order.
    # The lookup path may end in »!« plus the name of a (single argument) »builtins.*« function,in which case the resolved value will be passed to that function and its return value is used instead (e.g. for »attrNames«, »attrValues«, »toJSON«, »catAttrs«, ...).
    # The names of the declared values are the lookup paths, with ».« and »!« replaced by »_« and »__«.
    # The symbol immediately following the lookup path (/builtin name) can be »}« or any other symbol that bash variable substitutions allow after the variable name (like »:«, »/«), eliminating the need to assign to a local variable to do things like replacements, fallbacks or substrings.
    # If the lookup path does not exist in »context«, then the value will be considered the same as »null«, and a value of »null« will result in a bash variable that is not defined (which can then be handled in the bash script).
    # Other scalars (bool, float, int, path) will be passed to »builtins.toString«, Lists will be mapped with »toString« and declared as bash arrays, attribute sets will be declared using »asBashDict« with their values »toString«ed as well.
    # Any other value (functions), and things that »builtins.toString« doesn't like, will throw here.
    substituteLazy = args@{ pkgs, scripts, context, helpers ? { }, }: let
        scripts = map (source: rec {
            text = builtins.readFile source; inherit source;
            parsed = builtins.split ''@\{([#!]?)([a-zA-Z][a-zA-Z0-9_.-]*[a-zA-Z0-9](![a-zA-Z][a-zA-Z0-9_.-]*[a-zA-Z0-9])?)([:*@\[#%/^,\}])'' text; # (first part of a bash parameter expansion, with »@« instead of »$«)
        }) args.scripts;
        decls = lib.unique (map (match: builtins.elemAt match 1) (builtins.filter builtins.isList (builtins.concatMap (script: script.parsed) scripts)));
        vars = pkgs.writeText "vars" (lib.concatMapStringsSep "\n" (decl: let
            call = let split = builtins.split "!" decl; in if (builtins.length split) == 1 then null else builtins.elemAt split 2;
            path = (builtins.filter builtins.isString (builtins.split "[.]" (if call == null then decl else builtins.substring 0 ((builtins.stringLength decl) - (builtins.stringLength call) - 1) decl)));
            resolved = lib.attrByPath path null context;
            applied = if call == null || resolved == null then resolved else (let
                split = builtins.filter builtins.isString (builtins.split "[.]" call); name = builtins.head split; args = builtins.tail split;
                func = builtins.foldl' (func: arg: func arg) (helpers.${name} or self.lib.my.${name} or lib.${name}) args;
            in func resolved);
            value = if (
                (builtins.isBool applied) || (builtins.isFloat applied) || (builtins.isInt applied) || (builtins.isPath applied)
            ) then builtins.toString applied else applied;
            name = builtins.replaceStrings [ "." "!" ] [ "_" "__" ] decl; #(builtins.trace decl decl);
        in (
                 if (value == null) then ""
            else if (builtins.isString value) then "${name}=${lib.escapeShellArg value}"
            else if (builtins.isList value) then "${name}=(${lib.escapeShellArgs (map builtins.toString value)})"
            else if (builtins.isAttrs value) then "declare -A ${name}=${"(\n${asBashDict { mkValue = name: builtins.toString; } value}\n)"}"
            else throw "Can't use value of unsupported type ${builtins.typeOf} as substitution for ${decl}" # builtins.isFunction
        )) decls);
    in ''
        source ${vars}
        ${lib.concatMapStringsSep "\n" (script: "source ${pkgs.writeScript (builtins.baseNameOf script.source) (
            lib.concatMapStringsSep "" (seg: if builtins.isString seg then seg else (
                "$"+"{"+(builtins.head seg)+(builtins.replaceStrings [ "." "!" ] [ "_" "__" ] (builtins.elemAt seg 1))+(toString (builtins.elemAt seg 3))
            )) script.parsed
        )}") scripts}
    '';

    # Used as a »system.activationScripts« snippet, this performs substitutions on a »text« before writing it to »path«.
    # For each name-value pair in »substitutes«, all verbatim occurrences of the attribute name in »text« are replaced by the content of the file with path of the attribute value.
    # Since this happens one by one in no defined order, the attribute values should be chosen such that they don't appear in any of the files that are substituted in.
    # If a file that is supposed to be substituted in is missing, then »placeholder« is inserted instead, and the activation snipped reports a failure.
    # If »enable« is false, then the file at »path« is »rm«ed instead.
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

    # Wraps a (bash) script into a "package", making »deps« available on the script's path.
    wrap-script = args@{ pkgs, src, deps, ... }: let
        name = args.name or (builtins.baseNameOf (builtins.unsafeDiscardStringContext "${src}"));
    in pkgs.runCommandLocal name {
        script = src; nativeBuildInputs = [ pkgs.makeWrapper ];
    } ''makeWrapper $script $out/bin/${name} --prefix PATH : ${lib.makeBinPath deps}'';

    # Simplifies a path (or any other string) such that it can be used as a systemd unit name.
    escapeUnitName = name: lib.concatMapStringsSep "" (s: if builtins.isList s then "-" else s) (builtins.split "[^a-zA-Z0-9_.\\-]+" name); # from nixos/modules/services/backup/syncoid.nix

    pathToName = path: (builtins.replaceStrings [ "/" ":" ] [ "-" "-" ] path);
    # (If »path« ends with »/«, then »path[0:-1]« is the closest "parent".)
    parentPaths = path: let parent = builtins.dirOf path; in if parent == "." || parent == "/" then [ ] else (parentPaths parent) ++ [ parent ];

}
