/*

# NixOS native and foreign Containers

Efforts to manage declarative NixOS-Containers and containers whose images are not related to NixOS through the same interfaces.
More abstractions to come ...


## Notes

* `virtualisation.oci-containers.` is just a wrapper around `docker/podman run` and as such not interesting.
* `pkgs.dockerTools.buildImage` builds a portable docker image from nix sources (so not interesting)
* `nix-prefetch-docker` produces hashes that can be fed into `pkgs.dockerTools.pullImage`
* `pkgs.dockerTools.exportImage` takes a layered image and reduces it to a single-layer image


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: specialArgs@{ config, pkgs, lib, nodes, ... }: let inherit (inputs.self) lib; in let
    cfg = config.th.target.containers;
    utils = import "${inputs.nixpkgs.outPath}/nixos/lib/utils.nix" { inherit (specialArgs) lib config pkgs; };

    types.storePath = lib.mkOptionType {
        name = "path in /nix/store"; check = x: (lib.isStorePath x) || (lib.isStorePath (builtins.head (builtins.split ":" x)));
        merge = loc: defs: let
            val = lib.mergeOneOption loc defs;
        in if !(builtins.isString val) || builtins.hasContext val then val else (let
            split = lib.wip.ifNull (builtins.match ''^(.*?):(sha256-.*)$'' val) (throw "Literal store path ${val} must be followed by :sha256-...");
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
                modules = lib.mkOption { description = "For containers that do use NixOS, the configuration's base modules(s)."; type = lib.types.listOf (lib.types.functionTo lib.types.anything); default = [ ]; };
                rootFS = lib.mkOption { description = ''
                    For non-NixOS containers, paths to filesystem roots that will be overlayed under a tmpfs. Higher indices will be mounted higher.
                    To ensure that the paths will be present on the final system, they must evaluate to nix store paths, that is, be nix derivations (nix build results) or existing store paths as literal strings followed by their content hash (»/nix/store/...:sha256-«).
                    The final filesystem must provide an init process at »/init«. The init process is expected to exit with code 133 if it wants to be restarted, and respond to »SIGRTMIN+3« by shutting down.
                    Specifying layers makes ».modules« largely defunct.
                ''; type = lib.types.listOf (types.storePath); default = [ ]; };
                sshKeys = lib.mkOption { description = "SSH keys that will be configured to allow direct login into the container as that user."; type = lib.types.attrsOf (lib.types.listOf lib.types.str); default = { }; };
            }; }));
            default = { primary = { }; };
        };
    }; };

    config = let
        hash = builtins.substring 0 8 (builtins.hashString "sha256" config.networking.hostName);

    in lib.mkIf cfg.enable (lib.mkMerge [ ({

        containers = lib.mapAttrs (name: cfg: lib.mkMerge [ ({
            nixpkgs = inputs.nixpkgs; # (probably defaults to the version where the »nixosSystem« function comes from, which should be the same one)

            config = { config, pkgs, ... }: { imports = [ ({
                # Start with the same »pkgs« as the host:
                # Setting »nixpkgs.pkgs = pkgs« would mean that all overlays that happen to be applied to the host »pkgs« (either directly at instantiation or via »config.nixpkgs.overlays«) are applied to the »pkgs« argument passed to all container modules.
                # But just because the host has an overlay applied does not mean that the container should also have it -- if it does, it should be applied again by including and enabling the respective module.
                # Also, applying overlays twice (when importing the same module again) is often, but not necessarily a no-op.
                nixpkgs.overlays = (builtins.concatLists (map (input: if input?overlay then [ input.overlay ] else if input?overlays then builtins.attrValues input.overlays else [ ]) (builtins.attrValues inputs)));
                # We start with a new set of modules with only this one, its imports, and the default ones from »nixpkgs« here, so import the modules from any other inputs again.
                imports = (map (input: input.nixosModule or (if input?nixosModules then { imports = builtins.attrValues input.nixosModules; } else { })) (builtins.attrValues (builtins.removeAttrs inputs [ "nixpkgs" ])));
            }) ({
                # Some base configuration:

                th.minify.enable = true; # don't let the container pull in all the stuff that the host avoided
                wip.base.enable = true;

                users.allowNoPasswordLogin = true; # TODO: why is this an issue?

            }) ({
                # Apply ».config«:
                imports = map (module: args@{ pkgs, ... }: module args) cfg.modules; # (apparently the module system only provides the »pkgs« arg if the function called (directly) names it)

            }) ({
                # Apply ».rootFS«:
                # (nothing to do, see below)

            }) ]; };

        }) (lib.mkIf (cfg.rootFS == [ ]) { # Root filesystem native NixOS container

            ephemeral = true; # use tmpfs for / inside the container, /nix/store is mounted from host (TODO: "Note that the container journal will not be linked to the host if this option is enabled.")

        }) (lib.mkIf (cfg.rootFS != [ ]) { # Root filesystem + init generic container

            ephemeral = false; # use /var/lib/containers/${name} for / inside the container
            path = lib.mkForce "/"; # »${path:-...}/init« gets sourced inside the container to resume the boot process
            # alternatively, replacing »config.system.build.bootStage2« with this should also work:
            bindMounts."/init" = { hostPath = "${pkgs.writeShellScript "foreign-container-init" ''
                ${pkgs.util-linux}/bin/umount -l /init /nix/store /run/wrappers /nix/var/nix/{daemon-socket,db,gcroots,profiles} # probably need to to this next-to-last
                exec /init # the actual container init executable
            ''}"; isReadOnly = true; };

        }) ({
            autoStart = true; timeoutStartSec = "1min"; # timeout, but for what exactly to happen? Ideas: The unit on the host to come up (again, measured how)? The container »systemd« to reach some ».target«? And then it suicides?

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
        fileSystems = lib.wip.mapMerge (name: cfg: if cfg.rootFS != [ ] then {
            "/var/lib/containers/${name}" = { fsType = "overlay"; device = "overlay"; options = [
                "lowerdir=${lib.concatStringsSep ":" (lib.reverseList cfg.rootFS)}"
                "workdir=/run/containers/${name}.workdir"
                "upperdir=/run/containers/${name}"
            ]; };
        } else { }) cfg.containers;
        # Upper and work dirs need to be on the same mount, but they also do have to exist, so create them:
        systemd.services = lib.wip.mapMerge (name: cfg: if cfg.rootFS != [ ] then let
            mountPoint = "${utils.escapeSystemdPath "/var/lib/containers/${name}"}.mount";
        in { "mkdir-${utils.escapeSystemdPath "/var/lib/containers/${name}"}" = {
            description = "Create mount points for container@${name} rootfs";
            wantedBy = [ mountPoint ]; before = [ mountPoint ];
            unitConfig.RequiresMountsFor = [ "/var/lib/containers/" ];
            unitConfig.DefaultDependencies = false; # needed to prevent a cycle
            serviceConfig.Type = "oneshot"; script = ''
                mkdir -p /var/lib/containers/${name} /run/containers/${name}.workdir /run/containers/${name}
            '';
        }; } else { }) cfg.containers;

        wip.services.dropbear.rootKeys = let
            # not sure whether this is secure and/or completely transparent, but is works well enough for now
            ssh-to-container = pkgs.writeShellScript "ssh-to-container" ''
                if [[ ! $SSH_ORIGINAL_COMMAND ]] ; then
                    exec machinectl -q shell "$1" # does this also simply run /bin/sh?
                else
                    exec machinectl -q shell "$1" /bin/sh -c "$SSH_ORIGINAL_COMMAND"
                fi
            '';
        in lib.concatLists (lib.mapAttrsToList (host: { sshKeys, ... }: lib.concatLists (lib.mapAttrsToList (user: keys: map (key: ''
            command="${ssh-to-container} ${user}@${host}" ${key}
        '') keys) sshKeys)) cfg.containers);


    }) ]);

}
