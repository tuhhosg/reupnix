/*

# NixOS native and foreign Containers

Efforts to manage declarative NixOS-Containers and containers whose images are not related to NixOS through the same interfaces.
More abstractions to come ...


## Notes

* `virtualisation.oci-containers.` is just a wrapper around `docker/podman run` and as such not interesting.
* `pkgs.dockerTools.buildImage` builds a portable docker image from nix sources (so not interesting)
* `nix-prefetch-docker` produces hashes that can be fed into `pkgs.dockerTools.pullImage`
* `pkgs.dockerTools.exportImage` takes a layered image and reduces it to a single-layer image


## Commands

```bash
 systemctl status container@name
 machinectl shell name
```


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: specialArgs@{ config, pkgs, lib, nodes, utils, extraModules, ... }: let lib = inputs.self.lib.__internal__; in let
    cfg = config.th.target.containers;
    hostConfig = config;

    types.storePath = lib.mkOptionType {
        name = "path in /nix/store"; check = x: (lib.isStorePath x) || (lib.isStorePath (builtins.head (builtins.split ":" x)));
        merge = loc: defs: let
            val = lib.mergeOneOption loc defs;
        in if !(builtins.isString val) || builtins.hasContext val then val else (let
            split = lib.fun.ifNull (builtins.match ''^(.*?):(sha256-.*)$'' val) (throw "Literal store path ${val} must be followed by :sha256-...");
            path = (builtins.elemAt split 0); sha256 = (builtins.elemAt split 1);
            name = lib.substring 44 ((lib.stringLength path) - 44) path;
        in builtins.path { inherit path name sha256; });
        # Both »builtins.path« and »builtins.fetchClosure« allow accessing external store paths in pure evaluation mode, and seem roughly equivalent (for that purpose): both require the path to exist and be valid to even evaluate it.
        # »fetchClosure« experimental and pointlessly queries a remote cache, »path« requires the redundant hash.
    };
in {

    options.th = { target.containers = {
        enable = lib.mkEnableOption "";
        containers = lib.mkOption {
            description = "";
            type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: { options = {
                name = lib.mkOption { description = "The container's name from the attribute name."; type = lib.types.str; default = name; readOnly = true; };
                modules = lib.mkOption { description = "For containers that do use NixOS, the configuration's base modules(s)."; type = lib.types.listOf ((lib.types.functionTo lib.types.anything) // { merge = loc: fns: (lib.head fns).value; }); default = [ ]; };
                rootFS = lib.mkOption { description = ''
                    For non-NixOS containers, paths to filesystem roots that will layered atop each other to form the rootfs. Higher indices will be mounted higher.
                    To ensure that the paths will be present on the final system, they must evaluate to nix store paths, that is, be nix derivations (nix build results) or existing store paths as literal strings followed by their content hash (»/nix/store/...:sha256-«).
                    Specifying layers makes ».modules« largely defunct.
                ''; type = lib.types.listOf (types.storePath); default = [ ]; };
                readOnlyRootFS = (lib.mkEnableOption "read-only `/`, if used with `.rootFS`"); #// { default = true; }; TODO: this will need at least »/var« and »/etc« writable or populated correctly, see »nixpkgs/nixos/modules/virtualisation/nixos-containers.nix#startScript«
                workingDir = lib.mkOption { description = "If used with `.rootFS`, CWD for the `.command`."; type = lib.types.nullOr lib.types.str; default = null; };
                command = lib.mkOption { description = "If used with `.rootFS`, the command to run inside the container. The command is expected to exit with code 133 if it wants to be restarted, and respond to »SIGRTMIN+3« by shutting down. Further, it has to fulfill the reaping duties of PID 1."; type = lib.types.listOf lib.types.str; default = [ ]; };
                env = lib.mkOption { description = "If used with `.rootFS`, environment variables to set for `.command`."; type = lib.types.attrsOf lib.types.str; default = { }; };
                sshKeys = lib.mkOption { description = "SSH keys that will be configured to allow direct login into the container as that user."; type = lib.types.attrsOf (lib.types.listOf lib.types.str); default = { }; };
            }; }));
            default = { primary = { }; };
        };
    }; };

    config = let
        hash = builtins.substring 0 8 (builtins.hashString "sha256" config.networking.hostName);

    in lib.mkIf cfg.enable (lib.mkMerge [ ({

        containers = lib.mapAttrs (name: cfg: lib.mkMerge [ ({
            nixpkgs = pkgs.path; # (the default)

            config = { config, pkgs, ... }: { imports = [ ({
                imports = (/* lib.trace (lib.length extraModules) */ extraModules); # (»extraModules« should include all modules applied to the host that are not unique to the host's functionality but are also not in »nixpkgs« (i.e. things that _could_ be in nixpkgs); »lib.fun.mkNixosConfiguration« adds all the library modules of this flake and its inputs, »lib.th.testing.overrideBase« can be used to add additional modules))
            }) ({
                # Some base configuration:

                th.minify.enable = true; # don't let the container pull in all the stuff that the host avoided
                wip.base.enable = true;

                system.stateVersion = lib.mkDefault hostConfig.system.stateVersion;
                users.allowNoPasswordLogin = true;

            }) ({
                # Apply ».config«:
                imports = map (module: let
                    attrs = module (builtins.functionArgs module);
                    pos = builtins.unsafeGetAttrPos (lib.head (lib.attrNames attrs)) attrs;
                in { _file = pos.file + ":" + (toString pos.line); imports = [ module ]; }) cfg.modules;

                #imports = map (module: args@{ pkgs, ... }: module args) cfg.modules; # (apparently the module system only provides the »pkgs« arg if the function called (directly) names it)

            }) ({
                # Apply ».rootFS«:
                # (nothing to do, see below)

            }) ]; _file = "${dirname}/containers.nix.md#baseConfig"; };

        }) (lib.mkIf (cfg.rootFS == [ ]) { # Root filesystem native NixOS container

            ephemeral = true; # use tmpfs for / inside the container, /nix/store is mounted from host (TODO: "Note that the container journal will not be linked to the host if this option is enabled.")

        }) (lib.mkIf (cfg.rootFS != [ ]) { # Root filesystem + init generic container

            ephemeral = false; # use /var/lib/nixos-containers/${name} for / inside the container
            path = lib.mkForce ((pkgs.writeTextFile ({ # (the nixos-container entry point is »${path}/init«)
                name = "container-init-${cfg.name}"; destination = "/init"; executable = true;
            } // { text = let
                esc = lib.escapeShellArg;
            in ''
                ${pkgs.util-linux}/bin/umount -l /run/wrappers || true
                ${pkgs.util-linux}/bin/umount -l /nix/var/nix/{daemon-socket,db,gcroots,profiles} || exit
                ${pkgs.util-linux}/bin/umount -l /nix/store || exit # probably need to do this next-to-last
                unset PRIVATE_NETWORK LOCAL_ADDRESS LOCAL_ADDRESS6 HOST_ADDRESS HOST_ADDRESS6 HOST_BRIDGE HOST_PORT
                export PATH=/usr/sbin:/usr/bin:/sbin:/bin
                echo "Launching container's ».command«:"
                ${if cfg.workingDir != null then "cd ${esc cfg.workingDir}" else "# no CWD"}
                ${lib.concatStringsSep "\n" (lib.mapAttrsToList (n: v: "export ${esc n}=${esc v}") cfg.env)}
                exec ${lib.concatMapStringsSep " " esc cfg.command}
            ''; })).overrideAttrs (old: { buildCommand = old.buildCommand + ''
                echo ${pkgs.system} >$out/system
            ''; }));

        }) ({
            autoStart = true; timeoutStartSec = if cfg.rootFS != [ ] then "Infinity" else "1min"; # timeout, but for what exactly to happen? Ideas: The unit on the host to come up (again, measured how)? The container »systemd« to reach some ».target«? And then it suicides?

        }) ({
            # More possible settings:

            #tmpfs = [ "/var" ]; # additional tmpfs'es to mount (redundant with ».ephemeral«)
            #bindMounts."/path" = { hostPath = "/volumes/${name}/path"; isReadOnly = false; }; # Anything that can be read-only should just be part of the image or configuration in the nix store. These need to exist on the host before the container can start.

            #additionalCapabilities = [ "CAP_NET_ADMIN" ];
            #allowedDevices = [ { modifier = "rw"; node = "/dev/net/tun"; } ]
            #enableTun = false; # enable the container to create and setup tunnel interfaces

            #macvlans = [ ]; # host interfaces from which macvlans will be created and moved into the container
            #interfaces = [ ]; # host interfaces to be moved into the container entirely

            #privateNetwork = false; # Whether to create a separate network namespace for the container and create a default »eth0« veth connected to »ve-${name}« on the host. The interface pair itself can be configured with the same attributes as the »containers.<name>.extraVeths«, but for access to the external networking, bridging or NAT configured ont he host is required.
            # ...

            #extraFlags = [ ]; # verbatim extra args to »systemd-nspawn«

        }) ]) cfg.containers;

        # For non-native containers, create an overlayfs where / will be bound to:
        fileSystems = lib.fun.mapMerge (name: cfg: if cfg.rootFS != [ ] then {
            "/var/lib/nixos-containers/${name}" = (if (lib.length cfg.rootFS == 1) && cfg.readOnlyRootFS then {
                options = [ "bind" "ro" ]; device = "${lib.head cfg.rootFS}";
            } else {
                fsType = "overlay"; device = "overlay";
                options = [
                    "lowerdir=${lib.concatStringsSep ":" (lib.reverseList cfg.rootFS)}"
                ] ++ (lib.optionals (!cfg.readOnlyRootFS) [
                    "workdir=/run/containers/${name}.workdir"
                    "upperdir=/run/containers/${name}"
                ]);
                depends = (map toString cfg.rootFS) ++ (lib.optional (!cfg.readOnlyRootFS) "/run/containers" );
            }) // {
                preMountCommands = ''
                    mkdir -p /var/lib/nixos-containers/${name}
                '' + (lib.optionalString (!cfg.readOnlyRootFS) ''
                    mkdir -p /run/containers/${name}.workdir /run/containers/${name}
                '');
            };
        } else { }) cfg.containers;

        wip.services.dropbear.rootKeys = let
            # not sure whether this is secure and/or completely transparent, but is works well enough for now
            ssh-to-container = pkgs.writeShellScript "ssh-to-container" ''
                if [[ ! $SSH_ORIGINAL_COMMAND ]] ; then
                    exec machinectl -q shell "$1" # does this also simply run /bin/sh?
                else
                    exec machinectl -q shell "$1" /bin/sh -c "$SSH_ORIGINAL_COMMAND"
                fi
            '';
        in lib.concatStrings (lib.mapAttrsToList (host: { sshKeys, ... }: lib.concatStrings (lib.mapAttrsToList (user: keys: lib.concatMapStrings (key: ''
            command="${ssh-to-container} ${user}@${host}" ${key}
        '') keys) sshKeys)) cfg.containers);


    }) ]);

}
