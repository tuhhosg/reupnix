/*

# Minifying NixOS

This is a collection of config snippets to decrease the closure size of a NixOS configuration (that is, its installation size).


## Status

This currently produces an installation whose root FS takes ~250MB on ext4 (`-O inline_data` saves about 5%).
The by far biggest package is currently `perl` with almost 60MB. Once `update-users-groups.pl` is replaced with a static file generator, perl should disappear.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
dirname: inputs: specialArgs@{ config, pkgs, lib, utils, ... }: let inherit (inputs.self) lib; in let
    cfg = config.th.minify;
    specialArgs' = specialArgs // { inherit inputs; }; # Apparently this module gets called and evaluated twice. Once with all »specialArgs« passed into the build, and once only with those that this module lists as names arguments.

    desiredSystemPackages = [ # (can check this against »lib.naturalSort (lib.unique (map (p: p.pname or p.name) nixosConfigurations.target.config.environment.systemPackages))«)
        "bash-5.1-p16" # inevitable
        "coreutils" # really no fun without
        "dbus" # dow we need this?
        "kmod" # unless we disable module support (which would run contraire to configurability) we'll have this anyway
        "iptables" # will probs have this anyway
        "linux-pam" # will have this anyway
        "shadow" # will have this anyway (and every user with a nologin shell adds this)
        "systemd" # clearly
    ];

    optionalModules = [
        "config/console.nix" # don't need a pretty console
        "config/locale.nix" # includes tzdata
        "system/boot/kexec.nix" # we don't plan to change the kernel at runtime
        "tasks/bcache.nix" # also don't need block dev caching
        "tasks/filesystems/ext.nix" # copies itself to initramfs (we do need some kernel modules)
        "tasks/filesystems/vfat.nix" # copies itself to initramfs (we do need some kernel modules)
        "tasks/lvm.nix" # don't need lvm or (currently) and dm layers
        "tasks/swraid.nix" # don't need software raid (defines some »availableKernelModules« and adds »pkgs.mdadm«)
    ];
in {

    options.th = { minify = {
        enable = lib.mkEnableOption "various approaches to shrink NixOS' closure size";
        topLevel = lib.mkOption { default = null; type = lib.types.anything; }; # See »ditchKernelCopy«.
    }; };

    imports = (
        map (lib.wip.makeNixpkgsModuleConfigOptional specialArgs') optionalModules
    ) ++ [
        # (None of these should have any effect by default!)
        (lib.wip.overrideNixpkgsModule specialArgs' "virtualisation/nixos-containers.nix" (module: {
            options.boot.interactiveContainers = (lib.mkEnableOption "interactive nixos-containers") // { default = true; };
            config.content.environment.systemPackages = lib.mkIf config.boot.interactiveContainers module.config.content.environment.systemPackages;
        }))
        (lib.wip.overrideNixpkgsModule specialArgs' "tasks/filesystems.nix" (module: {
            options.includeFSpackages = (lib.mkEnableOption "inclusion of filesystem maintenance tools") // { default = true; };
            config.environment.systemPackages = lib.mkIf config.includeFSpackages module.config.environment.systemPackages; # adds fuse
            config.system.fsPackages = lib.mkIf config.includeFSpackages module.config.system.fsPackages; # adds dosfstools
        }))
        (lib.wip.overrideNixpkgsModule specialArgs' "tasks/network-interfaces.nix" (module: {
            options.includeNetTools = (lib.mkEnableOption "inclusion of basic networking utilities") // { default = true; };
            config.environment.systemPackages = lib.mkIf config.includeNetTools module.config.environment.systemPackages; # adds [ host iproute2 iputils nettools ]
            config.systemd.services.network-local-commands = lib.mkIf config.includeNetTools module.config.systemd.services.network-local-commands; # implements »config.networking.localCommands« using with iproute2
            #config.security.wrappers.ping = lib.mkIf config.includeNetTools module.config.security.wrappers.ping; # adds »ping« based on »iputils«
        }))

    ] ++ (lib.mapAttrsToList (name: config: let
        enable = lib.mkOption { description = config.description or ""; type = lib.types.bool; default = (config.enableByDefault or true) && cfg.enable; };
    in {
        options.th.minify.${name} = if config?options then { inherit enable; } // config.options else enable;
        config = lib.mkIf (if config?options then cfg.${name}.enable else cfg.${name}) (builtins.removeAttrs config [ "description" "enableByDefault" "options" ]);
    }) {

        reduceDefaults = ({
            description = ''Set defaults to disable some general things'';

            environment.includeRequiredPackages = lib.mkDefault false; # see nixpkgs/nixos/modules/config/system-path.nix
            environment.defaultPackages = lib.mkDefault [ ]; # default: nano perl rsync strace
            environment.systemPackages = (with pkgs; [ coreutils ]); # really no fun without

            documentation.enable = lib.mkDefault false; # this has an impact across the board
            documentation.man.enable = lib.mkDefault config.documentation.enable;
            hardware.enableRedistributableFirmware = lib.mkDefault false;

            # The system's "toplevel" tends to sometimes have a build dependency on »bootStage1« which nix thinks depends on »extra-utils«, the latter being quite big.
            # That wouldn't matter much, but the system builder adds a runtime reference to the script, while usually explicitly avoiding to make it a build dependency.
            # Only if there is a build dependency on and runtime reference to something (and the latter can normally only exist if the former does) nix will make the thing a runtime dependency.
            # These two lines avoid that by removing the reference and adds it to /etc, which is less likely to have a build dependency on the init script.
            # TODO: look into »disallowedRequisites« for this
            system.extraSystemBuilderCmds = if !config.boot.initrd.enable then "" else lib.mkAfter ''rm -f $out/boot-stage-1.sh'';
            environment.etc."boot-stage-1.sh" = lib.mkIf config.boot.initrd.enable { source = builtins.unsafeDiscardStringContext config.system.build.bootStage1; };

            # TODO: put these somewhere:
            networking.dhcpcd.enable = lib.mkDefault false;
            xdg.sounds.enable = lib.mkDefault false;
            xdg.mime.enable = lib.mkDefault false;
            fonts.fontconfig.enable = lib.mkDefault false;
        });

        removeNix = ({
            description = ''Disable/exclude Nix: The system won't be able to update/change itself.'';
            nix.enable = false;
            #system.extraSystemBuilderCmds = lib.mkAfter ''rm -f $out/config'';
            #system.extraSystemBuilderCmds = lib.mkForce ""; # For output path stability (the path not changing unless something actually changed) it is important to not just remove this from the build output but also to not even include it in the input. Without this, changes in the input sources do not immediately cause the toplevel derivation to change.
            system.disableInstallerTools = true;
            systemd.tmpfiles.rules = [ # »nixos-containers«/»config.containers« expect these to exist and fail to start without
                ''d  "/nix/var/nix/db"             0555  root root  -''
                ''d  "/nix/var/nix/daemon-socket"  0555  root root  -''
            ];
            wip.base.includeInputs = false;
        });

        disableLiveSwitching = ({
            description = ''
                Remove »switch-to-configuration«:
                The config can't be switched to at runtime, and the bootloader needs to be installed explicitly.
                This depends on the »../patches/nixpkgs-make-bootable-optional.patch« patch.
            '';
            system.build.makeSwitchable = false; # depends on perl and the bootloader installer
            systemd.shutdownRamfs.enable = lib.mkDefault false;
        });

        removeNano = ({
            description = ''Remove »nano«'';
            environment.defaultPackages = lib.mkDefault [ ]; # contains nano
            programs.nano.syntaxHighlight = lib.mkDefault false; # depends on nano
            #environment.variables.EDITOR = ?? (we don't have one)
        });

        removeTzdata = ({
            description = ''Remove »tzdata«'';
            disableModule."config/locale.nix" = true;
            systemd.managerEnvironment.TZDIR = lib.mkForce "";
        });

        staticDNS = ({
            description = ''Apply DNS settings statically: This implicitly disables the »resolvconf« service(s).'';
            environment.etc."resolv.conf" = lib.mkDefault { text = "${lib.concatMapStringsSep "\n" (ip: "nameserver ${ip}") config.networking.nameservers}\n"; };
        });

        removeAdminTools = ({
            description = ''Remove various sysadmin tools'';

            includeFSpackages = false; # all's good as long as it boots
            includeNetTools = false; # »ping db.de« still works (also removing ping would save another MB, but makes this baseline test harder)

            security.polkit.enable = false; # depends on spidermonkey (~32MB), which depends on icu4c (~32MB)
            services.udisks2.enable = false; # depends on boost (~15MB), and on (a different version of) icu4c (~32MB)
            security.sudo.enable = false; # »sudo«: ~5MB. May or may not need this.

            disableModule."config/console.nix" = true; # don't need a pretty console
            disableModule."tasks/bcache.nix" = true; # also don't need block dev caching
            disableModule."tasks/lvm.nix" = true; # don't need lvm or (currently) and dm layers
            disableModule."tasks/swraid.nix" = true; # don't need software raid (defines some »availableKernelModules« and adds »pkgs.mdadm«)

            # This probably shouldn't be here:
            disableModule."system/boot/kexec.nix" = true; # we don't plan to change the kernel at runtime
        });

        removeFsTools = ({
            description = ''Remove file system tooling'';

            # Mentioning a filesystem in »config.fileSystems« makes NixOS include the maintenance tools for that FS. »e2fsprogs« has ~5MB.
            disableModule."tasks/filesystems/vfat.nix" = true;
            boot.initrd.kernelModules = lib.mkIf (lib.any (fs: fs == "vfat") config.boot.initrd.supportedFilesystems) [ "vfat" "nls_cp437" "nls_iso8859-1" ]; # do need these
            disableModule."tasks/filesystems/ext.nix" = true;
            boot.initrd.availableKernelModules = lib.mkIf (lib.any (fs: fs == "ext4") config.boot.initrd.supportedFilesystems) [ "ext4" ];
            boot.initrd.checkJournalingFS = false; # allow ditching »tasks/filesystems/ext.nix«

            # The default setup of »/var/empty« requires »e2fsprogs« for a »chattr +i« on it. TODO: instead mount a read-only tmpfs here?
            system.activationScripts.var = lib.mkForce ''
                # Various log/runtime directories.

                mkdir -m 1777 -p /var/tmp

                # Empty, immutable home directory of many system accounts.
                mkdir -p /var/empty
                # Make sure it's really empty
                #/bin/chattr -f -i /var/empty || true
                find /var/empty -mindepth 1 -delete
                chmod 0555 /var/empty
                chown root:root /var/empty
                #/bin/chattr -f +i /var/empty || true
            '';
        });

        disableLocalization = ({
            description = ''Disable localization'';

            # the default »pkgs.glibc-locales« has ~215MB
            #i18n.supportedLocales = [ "C.UTF-8/UTF-8" ]; i18n.defaultLocale = "C.UTF-8/UTF-8";
            i18n.supportedLocales = [ ]; i18n.defaultLocale = "C";
            # ... there is quite a bit more to be done here, often within packages ...
        });

        useSimpleBash = ({
            description = ''
                Downgrade »bashInteractive« to simple »bash«:
                Use »bash« (needed anyway) instead of »bash-interactive«, which drops some dependencies (e.g. »ncurses«). Also, get rid of »ncurses« in general.
            '';
            nixpkgs.overlays = [ (final: prev: {
                bashInteractive = final.bash; # (this does cause many packages (systemd, nix, git, cargo, ...) to rebuild, which may be counter-productive in the longer run ...)
                git = prev.git.overrideAttrs (old: { doInstallCheck = false ; }); # takes forever and then fails (it's going to be fine ^^)
                util-linux = prev.util-linux.override { ncursesSupport = false; ncurses = null; };
            }) ];
            programs.bash.enableCompletion = false;
            programs.less.enable = lib.mkForce false; environment.variables.PAGER = lib.mkForce "cat"; # default depends on less and ncurses
            programs.command-not-found.enable = false; # depends on perl (and more)
            programs.bash.promptInit = ''
                # Provide a less nice prompt that the dumb shell can deal with:
                if [ "''${TERM:-}" != "dumb" ] ; then
                    PS1='$(printf "%-+ 4d" $?)[\D{%Y-%m-%d %H:%M:%S}] \u@\h:\w'"''${TERM_RECURSION_DEPTH:+["$TERM_RECURSION_DEPTH"]}"'\$ '
                fi
                export TERM_RECURSION_DEPTH=$(( 1 + ''${TERM_RECURSION_DEPTH:-0} ))
            '';
        });

        etcAsOverlay = ({
            description = ''
                Rewrite »activationScripts.etc« to remove its dependency on »perl«:
                Note that this is somewhat incomplete as it makes everything in etc a symlink to a root owned, world-readable file (or dir of those).
                While logically there is no way of avoiding that, since everything in the nix store must be non-writable and is readable by everyone, some programs don't like it (e.g. OpenSSH).
                »nixos/modules/system/etc/setup-etc.pl« allows for (snake-oil) exceptions based on ».{mode,uid,gid}« suffixed files, but none of them are relevant for this minimal config (just yet).

                This version mounts a writable tmpfs overlay over the static etc, allowing the creation on not-world-readable files by activation scripts.
            '';
            enableByDefault = false;
            # TODO: both of these could use »config.fileSystems« (see »./target/containers.nix.md« for mount sources)!
            # The new etc script must run before any write to »/etc«.
            system.activationScripts.etc = lib.mkForce "";
            system.activationScripts."AA-etc" = { deps = [ "specialfs" ]; text = ''
                mkdir -pm 000 /run/etc-overlay ; mkdir -p 755 /run/etc-overlay/{workdir,upperdir}
                mount -t overlay overlay -o lowerdir=${config.system.build.etc}/etc,workdir=/run/etc-overlay/workdir,upperdir=/run/etc-overlay/upperdir /etc
            ''; };
            boot.initrd.kernelModules = [ "overlay" ]; # the activation scripts are run between initrd and systemd, so apparently the module must (have been) loaded in initrd
            # This mount can't be done as »config.fileSystems."/etc"«, because it would be »neededForBoot« (to be available in the activation scripts), and that would make the initramfs depend on »config.system.build.etc«, which would cause a new build of the initramfs on any change to etc.
        });
        etcAsReadonly = ({
            description = ''
                Like ».etcAsOverlay«, but this version simply mounts the static etc completely read-only, which may very well not work with many configurations.
            '';
            enableByDefault = !cfg.etcAsOverlay;
            # Do this early to get errors if anything later writes to »/etc«.
            system.activationScripts.etc = lib.mkForce "";
            system.activationScripts."AA-etc" = { deps = [ "specialfs" ]; text = ''
                mkdir -pm 000 /etc ; mount -o bind,ro ${config.system.build.etc}/etc /etc
            ''; };
            environment.etc.mtab.source = "/proc/mounts"; # (»lib.types.path« only allows absolute targets)
            environment.etc.NIXOS.text = ""; # some tooling wants this to exist
            systemd.services.systemd-tmpfiles-setup.serviceConfig.ExecStart = [ "" "systemd-tmpfiles --create --remove --boot --exclude-prefix=/dev --exclude-prefix=/etc" ];
            environment.etc.dropbear = lib.mkIf config.wip.services.dropbear.enable { source = "/run/user/0"; };

        });

        staticUsers = ({
            description = ''
                Remove »activationScripts.users« and replace it by static shadow files (to remove the dependency on »perl«).
                Hashed passwords will be world-readable (and may therefore only be set via ».hashedPassword«), and all added users and groups will need fixed IDs.
            '';
        } // (let
            getGid = g: toString (lib.wip.ifNull g.gid (throw "Group ${g.name} has no GID"));
            getUid = u: toString (lib.wip.ifNull u.uid (throw "User ${u.name} has no UID"));
        in {
            system.activationScripts.users = lib.mkForce "";
            users.mutableUsers = false; assertions = [ { assertion = config.users.mutableUsers == false; message = "Static user generation is incompatible with »users.mutableUsers = true«."; } ];

            # Statically generate user files:
            environment.etc.group.text  = "${lib.concatMapStringsSep "\n" (g: (
                "${g.name}:x:${getGid g}:${lib.concatStringsSep "," g.members}"
            )) (lib.attrValues config.users.groups)}\n";
            environment.etc.passwd.text = "${lib.concatMapStringsSep "\n" (u: (
                "${u.name}:x:${getUid u}:${if lib.wip.matches ''[0-9]+$'' u.group then u.group else if config.users.groups?${u.group} then getGid config.users.groups.${u.group} else throw "User ${u.name}'s group ${u.group} does not exist"}:${u.description}:${u.home}:${utils.toShellPath u.shell}"
            )) (lib.attrValues config.users.users)}\n";
            environment.etc.shadow = { text = "${lib.concatMapStringsSep "\n" (u: (
                if u.password != null || u.passwordFile != null then throw "With static user generation, user passwords may only be set as ».hashedPassword« (check user ${u.name})" else
                "${u.name}:${lib.wip.ifNull u.hashedPassword "!"}:1::::::"
            )) (lib.attrValues config.users.users)}\n"; }; # mode = "640"; gid = config.ids.gids.shadow; }; # A world-readable shadow file kind of defats its own purpose, but systems that use this shouldn't have passwords anyway (and anything written here would already be world-readable in the store anyway).

            # Ensure all users/groups have static IDs. Use »config.ids« as intermediary to make undetected conflicts less likely. (Should scan for duplicates.)
            ids = { uids = {
                dhcpcd = 133; # (reserved but not actually set)
            }; gids = {
                systemd-coredump = config.ids.uids.systemd-coredump;
                #shadow = 318; # (reserved but not actually set)
                dhcpcd = 133; # (reserved but not actually set)
            }; };
            users.groups.systemd-coredump.gid = config.ids.gids.systemd-coredump;
            users.users.dhcpcd = { uid = config.ids.uids.dhcpcd; group = "dhcpcd"; };
            users.groups.dhcpcd.gid = config.ids.gids.dhcpcd;
        }));

        ditchKernelCopy = ({
            description = ''
                Allow installation without redundant kernel and initramfs copy in the nix store (assuming it is already on a separate »/boot« partition).
                Using »th.minify.topLevel« as copy and install target instead of »config.system.build.toplevel« drops the store dependencies on the kernel and initrd.
                The symbolic linking is necessary for the bootloader-installer to pick up the files to be copied (and is is assumed that the full system will be build and made available to the installer).
                Nix needs to be called with »--impure« when evaluating this.
            '';
            enableByDefault = false;

            th.minify.topLevel = lib.foldr (args: drv:
                pkgs.replaceDependency { oldDependency = args.old; newDependency = args.new or (pkgs.writeText args.old.name (builtins.unsafeDiscardStringContext "removed ${args.old}")); inherit drv; }
            ) config.system.build.toplevel [
                #{ old = config.system.build.extraUtils; } # (the initrd sporadically pulls this in, but that doesn't matter without initrd (https://github.com/NixOS/nix/issues/5633#issuecomment-1033001139))
                # TODO: look into »disallowedRequisites« for this
                rec { old = config.system.build.initialRamdisk; new = pkgs.runCommandLocal old.name {
                    old = builtins.unsafeDiscardStringContext old;
                } "mkdir $out ; ln -sfT $old/initrd $out/initrd"; }
                rec { old = config.boot.kernelPackages.kernel; new = pkgs.runCommandLocal old.name {
                    old = builtins.unsafeDiscardStringContext old;
                    modules = pkgs.runCommandLocal old.name { } "mkdir $out ; cp -a ${old}/lib $out/lib";
                } "mkdir $out ; ln -sfT $old/bzImage $out/bzImage ; cp -a $modules/lib $out/lib"; }
            ];
            system.build.initialRamdiskSecretAppender = lib.mkForce "";
        });

        declarativeContainersOnly = ({
            description = ''
                Remove imperative »nixos-container«s and break reloading of containers. Declarative containers themselves still work.
                The interactive »pkgs.nixos-container« CLI does depend on »perl«, static containers do only by calling that CLI from »ExecReload«.
            '';
            boot.interactiveContainers = false;
            systemd.services = lib.wip.mapMerge (name: { "container@${name}".serviceConfig.ExecReload = lib.mkForce ""; }) ([ "" ] ++ (lib.attrNames config.containers));
        });

        shrinkSystemd = ({
            description = ''Shrink »systemd«: The default NixOS systemd is built with support for pretty much everything. This remove most of that.'';
            nixpkgs.overlays = [ (final: prev: {
                # nixpkgs/pkgs/os-specific/linux/systemd/default.nix#L608
                systemd = (prev.systemd.override {
                    # keys taken from definition of »systemd-minimal« in »pkgs/top-level/all-packages.nix:23048«:
                    withAnalyze = false; # sufficient to do beforehand?
                    withApparmor = false;
                    withCompression = false;
                    withCoredump = false;
                    withCryptsetup = false; # nope
                    withDocumentation = false; # nope
                    withEfi = true; # needed when booting that way?
                    withFido2 = false; # nope
                    withHostnamed = false;
                    withHwdb = false; # TODO
                    withImportd = false;
                    withLibBPF = false;
                    withLocaled = false;
                    withLogind = true; # TODO
                    withMachined = true; # for login to containers
                    withNetworkd = false;
                    withNss = false; # nope ("name service switch")
                    withOomd = false; # we don't want to run out of memory anyway
                    withPCRE2 = false; # (but what for?)
                    withPolkit = false;
                    withRemote = false; # ? -D remote ?
                    withResolved = false; # TODO: currently, this is expected!
                    withShellCompletions = false; # nope
                    withTimedated = false;
                    withTimesyncd = false;
                    withTpm2Tss = false;
                    withUserDb = false;
                    #glib = null;
                    libgcrypt = null;
                    #lvm2 = null; removed around 2022-04-03/9?
                    libfido2 = null;
                    p11-kit = null;
                });
            }) ];
            services.nscd.enable = false; system.nssModules = lib.mkForce [ ];
            systemd.suppressedSystemUnits = [ # (the test to automatically exclude these does for some reason not work)
                "cryptsetup.target" "cryptsetup-pre.target" "remote-cryptsetup.target" # withCryptsetup

                #"systemd-logind.service" "autovt@.service" "systemd-user-sessions.service" "dbus-org.freedesktop.machine1.service" "dbus-org.freedesktop.login1.service" "user@.service" "user-runtime-dir@.service" # withLogind

                "systemd-coredump.socket" "systemd-coredump@.service" # withCoredump

                "systemd-importd.service" "dbus-org.freedesktop.import1.service" #withImportd

                "systemd-timedated.service" "systemd-timesyncd.service" "systemd-localed.service" "dbus-org.freedesktop.timedate1.service" "dbus-org.freedesktop.locale1.service" # withTimedated/withTimesyncd
                "systemd-hostnamed.service" "dbus-org.freedesktop.hostname1.service" # withHostnamed
            ];
        });

        shrinkKernel = ({
            description = ''
                Reduce the kernel size by removing unused modules.
                Run »ssh target lsmod | (read -r; printf "%s\n" "$REPLY"; sort) >./lsmod.out« to record the module usage at runtime and pass the resulting file as ».shrinkKernel.usedModules«.
                »make localmodconfig« then filters everything that the default kernel config selected as "module" (which are most things) against the »lsmod« output and deselects everything that isn't used.
                In case that removes something that is actually needed, at some other time, in a different specialisation, etc, add it to the »explicit« list.
                In the minimal VirtualBox example, this reduces the size of the 5.15 kernel from 120MB to 14MB.
            '';
            enableByDefault = cfg.shrinkKernel.usedModules != null;
            options = {
                baseKernel = lib.mkOption { description = "Base kernel to shrink."; type = lib.types.package; default = pkgs.linuxPackages.kernel; };
                usedModules = lib.mkOption { description = "Output of »lsmod« used in »make LSMOD=\${shrinkKernel.usedModules} localmodconfig« to remove all modules that are unused (at the time »lsmod« is called) from the kernel package."; type = lib.types.nullOr lib.types.path; default = null; };
                overrideConfig = lib.mkOption { description = "Config flags to force to a specific value after applying »make localmodconfig«."; type = lib.types.attrsOf lib.types.str; default = { }; };
            };

            # further optimizations: lto,
            # $ wget -qO- https://cdn.kernel.org/pub/linux/kernel/v5.x/linux-5.15.30.tar.xz | xzcat - | tar -xf- --strip-components=1
            th.minify.shrinkKernel.overrideConfig = {
                CRYPTO_USER_API_HASH = "m"; AUTOFS4_FS = "m"; # else assertion fails
                SATA_AHCI = "m"; # »ahci« module
            };

            boot.kernelPackages = let
                base = cfg.shrinkKernel.baseKernel;
                configfile = pkgs.stdenv.mkDerivation {
                    inherit (base) version src; pname = "linux-localmodconfig";
                    inherit (base.configfile) depsBuildBuild nativeBuildInputs;
                    baseConfig = base.configfile; usedModules = cfg.shrinkKernel.usedModules;
                    overrideConfig = lib.concatStringsSep " " (lib.mapAttrsToList (k: v: if v == null then "" else "CONFIG_${k}=${v}") cfg.shrinkKernel.overrideConfig);
                    buildPhase = ''( set -x
                        cp $baseConfig .config
                        make LSMOD=$usedModules localmodconfig
                        for var in $overrideConfig ; do
                            perl -pi -e 's;^(# )?'"''${var/=*/}"'\b.*;'"$var"';' .config
                        done
                    )'';
                    installPhase = ''mv .config $out'';
                };
                kernel = pkgs.linuxKernel.customPackage {
                    inherit (base) version src; inherit configfile;
                    allowImportFromDerivation = true; # This allows parsing the config file (after building it), but to what end?
                };
            in pkgs.linuxPackagesFor kernel.kernel;

            boot.initrd.includeDefaultModules = false; # we don't need most of them, and thus didn't build them
            boot.initrd.availableKernelModules = [ "ahci" "sd_mod" ];

        });

    });

    ## Notes on removing even more NixOS default dependencies:

    #  ncdu -x /tmp/nixos-install-target/nix/store/
    #  nix why-depends --all /tmp/nixos-install-target/run/current-system /nix/store/... | cat

    # Things we still have (to keep, reduce, or get rid of):
    # »linux«: ~90MB/120MB. The linux kernel plus modules. See efforts on this below.
    # »perl«: ~57MB. A number of things depend on perl (activate(.sh) [nixos/modules/config/update-users-groups.pl, nixos/modules/system/etc/setup-etc.pl (solved)], nixos-container(.pl) (though this is only needed for interactive management (and service reload), static containers don't need the "binary")). The bulk of it is (standard) libraries, (TODO) much of that concerned with localization. »nixos/modules/config/update-users-groups.pl« really just writes »/etc/{passwd,groups,shadow}« and would do some (here irrelevant) transitional things.
    # »glibc«: ~32MB. Won't get rid of it entirely, but currently (TODO) most of this is locales stuff (i18n + gconv (string encoding)).
    # »systemd«: ~28MB; »systemd-minimal«: ~14MB. The »-minimal« is an internal thing to break dependency loops (or something like that, see https://github.com/NixOS/nixpkgs/issues/98094). But it proofs that »systemd« itself can be reduced in size quite a bit, which also drops other dependencies (e.g. on »cryptsetup«). EDIT: »systemd« is now down to 14MB, and the reduction in dependencies also removed the »systemd-minimal« redundancy.
    # »extra-utils«: ~20MB. These are utilities packed together to be copied into the initramfs. Some are unnecessary (e.g. mdadm), but address that when writing a »stage-1-init.sh« that works without initramfs.
    # »initrd-linux«: ~10MB. The packed initrd. Having this in the store is completely redundant. (TODO) This could be deleted (but probably there is no elegant way to do that).
    # »util-linux-*-lib«: ~9MB. (TODO) 7.8MB of this is in »share/locale«.
    # »hwdb.bin«: ~9MB. Hardware rule definitions for udev. Empty now.
    # »util-linux-*-bin«: ~6MB. This exists twice (TODO: get rid of one). Some of the tools are required (e.g. mount), (TODO) others not (e.g. fdisk).
    # »gcc-*-lib«: ~6MB. This seem to be runtime libraries (»libstdc++.so.6.0.28« etc), not gcc itself.
    # kbd: TODO: remove
    # »shadow«: ~4MB. User management tools. TODO: (try to) remove.
    # »openssl«: ~4MB. Dependency of: systemd (plus these of its dependencies directly use it: curl, tpm2-tss), and these depend on systemd: util-linux, dbus.
    # perl-5.34.0-man -.-
    # ... plus about 120 packages from 4MB to 50KB, then it's just about 180 (dirs of) scripts, config files, and empty files/dirs.


    # remove stuff that really isn't a _runtime_ dependency at all:
    #system.replaceRuntimeDependencies = map (pkg: { original = pkg; replacement = pkgs.writeText pkg.name (builtins.unsafeDiscardStringContext "removed ${pkg}"); }) [
    #    #pkgs.gcc # gcc-10.3.0-lib: ~6MB # (this seem to actually be runtime libraries (»libstdc++.so.6.0.28« etc), not gcc itself)
    #];

}
