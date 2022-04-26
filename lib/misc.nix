dirname: inputs@{ self, nixpkgs, ...}: let
    inherit (nixpkgs) lib;
    inherit (import "${dirname}/vars.nix" dirname inputs) startsWith;
in rec {

    ## Logic Flow

    notNull = value: value != null;

    ifNull      = value: default:   (if   value == null then default else value);
    withDefault = default: value:   (if   value == null then default else value);
    passNull = mayNull: expression: (if mayNull == null then null    else expression);


    ## Misc

    # Creates a package for `config.systemd.packages` that adds an `override.conf` to the specified `unit` (which is the only way to modify a single service template instance).
    mkSystemdOverride = pkgs: unit: text: (pkgs.runCommandNoCC unit { preferLocalBuild = true; allowSubstitutes = false; } ''
        mkdir -p $out/${lib.escapeShellArg "/etc/systemd/system/${unit}.d/"}
        <<<${lib.escapeShellArg text} cat >$out/${lib.escapeShellArg "/etc/systemd/system/${unit}.d/override.conf"}
    '');

    # Given »config.ids« (or equivalent) and a user name, returns the users numeric »uid:gid« pair as string.
    getOwnership = { gids, uids, ... }: user: "${toString uids.${user}}:${toString gids.${user}}";

    # Given »from« and »to« as »config.my.network.spec.hosts.*«,
    # picks the first of »to«'s IPs whose required subnet is either empty/any, or a prefix to any of the subnets in »from«:
    # ip = preferredRoute self.subNets other.routes;
    # ip6 = preferredRoute self.subNets (builtins.filter (r: r.is6) other.routes);
    # to.find(({ ip, prefix }) => from.any(_=>_.startsWith(prefix))).ip
    preferredRoute = from: to: (lib.findFirst ({ prefix, ip, ... }: prefix == "" || (builtins.any (fromSub: startsWith prefix fromSub) from)) { ip = ""; } to).ip;

    # Given a message and any value, traces both the message and the value, and returns the value.
    trace = lib: message: value: (builtins.trace (message +": "+ (lib.generators.toPretty { } value)) value);

    rpoolOf = hostName: "rpool-${builtins.substring 0 8 (builtins.hashString "sha256" hostName)}";

}
