/*

# Minifying NixOS

This is a collection of config snippets to decrease the closure size of a NixOS configuration (that is, its installation size).


## Status

This currently produces an installation whose root FS takes ~250MB on ext4 (`-O inline_data` saves about 5%).
The by far biggest package is currently `perl` with almost 60MB. Once `update-users-groups.pl` is replaced with a static file generator, perl should disappear.


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS module:
specialArgs@{ config, lib, pkgs, inputs, specialisation, ... }: let
    cfg = config.th.minify;
    moduleArgs = { utils = import "${inputs.nixpkgs.outPath}/nixos/lib/utils.nix" { inherit (specialArgs) lib config pkgs; }; } // specialArgs;

    ## Given a path to a module in »nixpkgs/nixos/modules/« and placed in another module's »imports«, adds an option »disableModule.<path>« that defaults to being false, but when explicitly set to »true«, disables all »config« values set by the module.
    #  Every module should, but not all modules do, provide such an option themselves.
    #  This is similar to adding the path to »disabledModules«, but:
    #  * leaves the module's other definitions (options, imports) untouched, preventing further breakage due to missing options
    #  * makes the disabling an option, i.e. it can be changed dynamically based on other config values
    makeModuleConfigOptional = modulePath: let
        fullPath = "${inputs.nixpkgs.outPath}/nixos/modules/${modulePath}";
        module = import fullPath moduleArgs;
    in { _file = fullPath; imports = [
        { options.disableModule.${modulePath} = lib.mkOption { description = "Disable the nixpkgs module ${modulePath}"; type = lib.types.bool; default = false; }; }
        (if module?config then (
            module // { config = lib.mkIf (!config.disableModule.${modulePath}) module.config; }
        ) else (
            { config = lib.mkIf (!config.disableModule.${modulePath}) module; }
        ))
        { disabledModules = [ modulePath ]; }
    ]; };

    ## Given a path to a module and a function taking the instantiation of the original and returning a partial module as override, recursively applies that override to the original module definition.
    #  This allows for much more fine-grained overriding of the configuration (or even other parts) of a module than »makeModuleConfigOptional«, but the override function needs to be tailored to internal implementation details of the original module.
    #  Esp. it is important to know that »mkIf« both existing in the original module and in the return from the override results in an attrset »{ _type="if"; condition; content; }«. Accessing content from an existing »mkIf« thus requires adding ».content« to the lookup path, and the »content« of returned »mkIf«s may get merged with any existing attribute of that name.
    overrideModule = modulePath: override: let
        fullPath = "${inputs.nixpkgs.outPath}/nixos/modules/${modulePath}";
        module = import fullPath moduleArgs;
    in { _file = fullPath; imports = [
        (lib.th.mergeAttrsRecursive [ module (override module) ])
        { disabledModules = [ modulePath ]; }
    ]; };

    desiredSystemPackages = [
        "iproute2" "iputils" "net-tools" # maybe
        "systemd" # clearly
        "kmod" # unless we disable module support (which would run contraire to configurability) we'll have this anyway
        "iptables" # will probs have this anyway
        "bash-5.1-p16" # inevitable
        "linux-pam" # will have this anyway
        "shadow" # will have this anyway (and every user with a nologin shell adds this)
        "dbus" # dow we need this?
    ];
    optionalModules = [
        "config/console.nix" # don't need a pretty console
        "tasks/swraid.nix" # don't need software raid (defines some »availableKernelModules« and adds »pkgs.mdadm«)
        "tasks/lvm.nix" # don't need lvm or (currently) and dm layers
        "tasks/bcache.nix" # also don't need block dev caching
        "system/boot/kexec.nix" # we don't plan to change the kernel at runtime
        "tasks/filesystems/vfat.nix" # copies itself to initramfs (we do need some kernel modules)
        "tasks/filesystems/ext.nix" # copies itself to initramfs (we do need some kernel modules)
    ];
in {

    options.th = { minify = {
        enable = lib.mkEnableOption "various approaches to shrink NixOS' closure size";
    }; };

    imports = (
        map makeModuleConfigOptional optionalModules
    ) ++ [
        # (None of these should have any effect by default!)
        (overrideModule "virtualisation/nixos-containers.nix" (module: {
            options.boot.interactiveContainers = (lib.mkEnableOption "interactive nixos-containers") // { default = true; };
            config.content.environment.systemPackages = lib.mkIf config.boot.interactiveContainers module.config.content.environment.systemPackages;
        }))
        (overrideModule "tasks/filesystems.nix" (module: {
            options.includeFSpackages = (lib.mkEnableOption "interactive nixos-containers") // { default = true; };
            config.environment.systemPackages = lib.mkIf config.includeFSpackages module.config.environment.systemPackages; # adds fuse
            config.system.fsPackages = lib.mkIf config.includeFSpackages module.config.system.fsPackages; # adds dosfstools
        }))
        (overrideModule "tasks/network-interfaces.nix" (module: {
            options.includeNetTools = (lib.mkEnableOption "inclusion of basic networking utilities") // { default = true; };
            config.environment.systemPackages = lib.mkIf config.includeNetTools module.config.environment.systemPackages; # adds [ host iproute2 iputils nettools ]
            config.systemd.services.network-local-commands = lib.mkIf config.includeNetTools module.config.systemd.services.network-local-commands; # implements »config.networking.localCommands« using with iproute2
            #config.security.wrappers.ping = lib.mkIf config.includeNetTools module.config.security.wrappers.ping; # adds »ping« based on »iputils«
        }))
    ];

    config = lib.mkIf cfg.enable (lib.mkMerge [
        ({
            # Some general things:

            environment.includeRequiredPackages = lib.mkDefault false; # see nixpkgs/nixos/modules/config/system-path.nix
            environment.defaultPackages = lib.mkDefault [ ]; # default: nano perl rsync strace
            environment.systemPackages = (with pkgs; [ coreutils ]); # really no fun without

            documentation.enable = lib.mkDefault false; # this has an impact across the board
            documentation.man.enable = lib.mkDefault config.documentation.enable;

            # TODO: put these somewhere:
            networking.dhcpcd.enable = lib.mkDefault false;
            xdg.sounds.enable = lib.mkDefault false;
            xdg.mime.enable = lib.mkDefault false;
            fonts.fontconfig.enable = lib.mkDefault false;
        })
        ({
            # Disable/exclude Nix:
            # The system won't be able to update/change itself.
            nix.enable = false;
            system.disableInstallerTools = true;
        })
        ({
            # Remove »switch-to-configuration«:
            # The config can't be switched to at runtime, and the bootloader needs to be installed explicitly.
            system.build.makeSwitchable = false; # depends on perl and the bootloader installer
        })
        ({
            # Remove »nano«:
            environment.defaultPackages = lib.mkDefault [ ]; # contains nano
            programs.nano.syntaxHighlight = lib.mkDefault false; # depends on nano
            #environment.variables.EDITOR = ?? (we don't have one)
        })
        ({
            # Static DNS settings:
            # This implicitly disables the »resolvconf« service(s).
            environment.etc."resolv.conf" = lib.mkDefault { text = "${lib.concatMapStringsSep "\n" (ip: "nameserver ${ip}") config.networking.nameservers}\n"; };
        })
        ({
            # Remove sysadmin tools:

            includeFSpackages = false; # all's good as long as it boots
            includeNetTools = false; # »ping db.de« still works (also removing ping would save another MB, but makes this baseline test harder)

            security.polkit.enable = false; # depends on spidermonkey (~32MB), which depends on icu4c (~32MB)
            services.udisks2.enable = false; # depends on boost (~15MB), and on (a different version of) icu4c (~32MB)
            security.sudo.enable = false; # »sudo«: ~5MB. May or may not need this.

            disableModule = lib.th.mapMerge (path: { ${path} = true; }) optionalModules; # see »optionalModules« above
        })
        ({
            # Disable localization:

            # the default »pkgs.glibc-locales« has ~215MB
            #i18n.supportedLocales = [ "C.UTF-8/UTF-8" ]; i18n.defaultLocale = "C.UTF-8/UTF-8";
            i18n.supportedLocales = [ ]; i18n.defaultLocale = "C";
            # ... there is quite a bit more to be done here, often within packages ...
        })
        ({
            # Downgrade »bashInteractive« to simple »bash«:
            # Use »bash« (needed anyway) instead of »bash-interactive«, which drops some dependencies (e.g. »ncurses«). Also, get rid of »ncurses« in general.
            nixpkgs.overlays = [ (final: prev: {
                bashInteractive = final.bash; # (this does cause many packages (systemd, nix, git, cargo, ...) to rebuild, which may be counter-productive in the longer run ...)
                git = prev.git.overrideAttrs (old: { doInstallCheck = false ; }); # takes forever and then fails (it's going to be fine ^^)
                util-linux = prev.util-linux.override { ncurses = null; };
            }) ];
            programs.less.enable = lib.mkForce false; environment.variables.PAGER = lib.mkForce "cat"; # default depends on less and ncurses
            programs.command-not-found.enable = false; # depends on perl (and more)
        })
        ({
            # Remove file system tooling:

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
        })
        ({
            # Rewrite »activationScripts.etc« to remove its dependency on »perl«:
            boot.initrd.kernelModules = [ "overlay" ];
            # The new etc script must run before any write to »/etc«.
            system.activationScripts.etc = lib.mkForce "";
            # NOTE: This is incomplete. Everything in etc is a symlink to a root owned, world-readable file (or dir of those).
            # »nixos/modules/system/etc/setup-etc.pl« allows for explicit exceptions based on ».{mode,uid,gid}« suffixed files, but none of them are relevant for this minimal config (just yet).
            system.activationScripts."AA-etc" = { deps = [ "specialfs" ]; text = ''
                mkdir -pm 000 /run/etc-overlay ; mkdir -p 755 /run/etc-overlay/{dynamic,workdir}
                mount -t overlay overlay -o lowerdir=${config.system.build.etc}/etc,workdir=/run/etc-overlay/workdir,upperdir=/run/etc-overlay/dynamic /etc
            ''; };
            system.activationScripts."zz-etc" = { deps = [ "wrappers" ]; text = ''
                # A simpler (and more performant, without the workdir?) way to create read-only overlays:
                # »mount -t overlay overlay -o ro,lowerdir=dynamic:static merged«
                # but that behaves weird when modifying »dynamic« after mounting. *Could* re-mount as this at the end of the overall activation.
            ''; };
            # An alternative to this would be to ensure that all files are in the etc package (we want static users anyway) and then (and this definitively is a hack) chown/chmod files in that package after the »nix copy«.
        })
        ({
            # Rewrite »activationScripts.users« to remove its dependency on »perl«:
            #system.activationScripts.users = lib.mkForce ""; # TODO: this needs an alternative implementation!
        })
        ({
            # Remove »nixos-container«'s dependency on »perl«:
            # The interactive »pkgs.nixos-container« CLI does depend on »perl«, static containers do only by calling that CLI from »ExecReload«.
            boot.interactiveContainers = false;
            systemd.services = lib.th.mapMerge (name: { "container@${name}".serviceConfig.ExecReload = lib.mkForce ""; }) ([ "" ] ++ (lib.attrNames config.containers));
        })
        ({
            # Shrink »systemd«:
            # The default NixOS systemd is built with support for pretty much everything. Remove most of that:
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
        })
        ({
        })


        ({
            ## Notes on removing even more NixOS default dependencies:

            #  ncdu -x /tmp/nixos-install-target/nix/store/
            #  nix why-depends --all /tmp/nixos-install-target/run/current-system /nix/store/...

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
            system.replaceRuntimeDependencies = map (pkg: { original = pkg; replacement = pkgs.writeText pkg.name (builtins.unsafeDiscardStringContext "removed ${pkg}"); }) [
                #pkgs.gcc # gcc-10.3.0-lib: ~6MB # (this seem to actually be runtime libraries (»libstdc++.so.6.0.28« etc), not gcc itself)
            ];

        })
        (lib.mkIf true {
            # Reduce kernel size by removing unused modules.
            # This reduces the size of the 5.15 kernel from 120MB to 14MB.
            # Run »ssh target lsmod >./lsmod.out« to record the module usage at runtime.
            # The »make localmodconfig« then filters everything that the default config selected as "module" against the »lsmod« output and deselects everything that isn't used.
            # In case that removes something that is actually needed, at some other time, in a different specialisation, etc, add it to the »explicit« list.

            # further optimizations: lto,
            # $ wget -qO- https://cdn.kernel.org/pub/linux/kernel/v5.x/linux-5.15.30.tar.xz | xzcat - | tar -xf- --strip-components=1

            # TODO: make »lsmod« file, »explicit«, and »availableKernelModules« options

            boot.kernelPackages = let
                base = pkgs.linuxPackages.kernel;
                configfile = pkgs.stdenv.mkDerivation {
                    inherit (base) version src; pname = "linux-localmodconfig";
                    inherit (base.configfile) depsBuildBuild nativeBuildInputs;
                    LSMOD = ./lsmod.out; oldConfig = base.configfile;
                    explicit = lib.concatStringsSep " " [ # values to replace after applying »localmodconfig«
                        "CONFIG_CRYPTO_USER_API_HASH=m CONFIG_AUTOFS4_FS=m" # else assertion fails
                    ];
                    buildPhase = ''( set -x
                        cp $oldConfig .config
                        make LSMOD=$LSMOD localmodconfig
                        for var in $explicit ; do
                            perl -pi -e 's|^(# )?'"''${var/=*/}"'\b.*|'"$var"'|' .config
                        done
                    )'';
                    installPhase = ''mv .config $out'';
                };
                kernel = pkgs.linuxKernel.customPackage {
                    inherit (base) version src; inherit configfile;
                    allowImportFromDerivation = true;
                };
            in pkgs.linuxPackagesFor kernel.kernel;

            boot.initrd.includeDefaultModules = false; # we don't need most of them, and thus didn't build them
            boot.initrd.availableKernelModules = [ "ahci" "sd_mod" ];

        })
    ]);

}
