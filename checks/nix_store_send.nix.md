/*

# `nix store send` Transfer


## System Definitions

```nix
#*/# end of MarkDown, beginning of Nix test:
dirname: inputs: pkgs: let
    lib = inputs.self.lib.__internal__; test = lib.th.testing pkgs;
    toplevels = lib.mapAttrs (n: v: test.toplevel v);
    flatten = attrs: lib.fun.mapMerge (k1: v1: lib.fun.mapMerge (k2: v2: { "${k1}_${k2}" = v2; }) v1) attrs;

    prep-system = system: test.override (test.unpinInputs system) ({ config, ... }: {
        # »override« does not affect containers, stacking »overrideBase« (for some reason) only works on the repl, and targeting the containers explicitly also doesn't work ...
        specialisation.test1.configuration.th.target.containers.containers = lib.mkForce { };

        # Can't reliably find references in compressed files:
        boot.initrd.compressor = "cat";
        # This didn't quite work (still uses gzip):
        #th.minify.shrinkKernel.overrideConfig.KERNEL_ZSTD = "n";
        #th.minify.shrinkKernel.overrideConfig.HAVE_KERNEL_UNCOMPRESSED = "y";
        #th.minify.shrinkKernel.overrideConfig.KERNEL_UNCOMPRESSED = "y";

        boot.loader.timeout = lib.mkForce 0; # boot without waiting for user input

        disableModule."system/boot/kexec.nix" = lib.mkForce false;
    });

    applications = ((lib.fun.importWrapped inputs "${dirname}/container-sizes.nix.md").required pkgs).images;
    add-all-apps = system: test.override system {
        imports = map (_:_.nixos or { }) (lib.attrValues applications);
        system.nixos.tags = [ "withApps" ];
    };

    mqttNixConfig = updated: {
        th.target.containers.enable = true;
        th.target.containers.containers.mosquitto = {
            modules = [ ({ pkgs, ... }: {

                th.minify.staticUsers = pkgs.system != "aarch64-linux"; # Without this, systemd inside the container fails to start the service (exits with »226/NAMESPACE«).

                services.mosquitto.enable = true;
                services.mosquitto.listeners = [ ]; # (bugfix)
                services.mosquitto.package = lib.mkIf updated (pkgs.mosquitto.overrideAttrs (old: rec { # from v2.0.14
                    pname = "mosquitto"; version = "2.0.15"; src = pkgs.fetchFromGitHub { owner = "eclipse"; repo = pname; rev = "v${version}"; sha256 = "sha256-H2oaTphx5wvwXWDDaf9lLSVfHWmb2rMlxQmyRB4k5eg="; };
                }));
            }) ];
        };
        th.target.containers.containers.zigbee2mqtt = {
            modules = [ ({ pkgs, ... }: {

                th.minify.staticUsers = pkgs.system != "aarch64-linux";

                services.zigbee2mqtt.enable = true;
                services.zigbee2mqtt.package = lib.mkIf updated (pkgs.callPackage "${inputs.new-nixpkgs}/pkgs/servers/zigbee2mqtt/default.nix" { }); # 1.25.0 -> 1.25.2 (it's an npm package with old packaging, and thus very verbose to update explicitly)

                systemd.services.zigbee2mqtt.serviceConfig.Restart = lib.mkForce "no";
            }) ];
            sshKeys.root = [ (lib.readFile "${inputs.self}/utils/res/ssh_testkey_2.pub") ];
        };
    };
    mqttOciConfig = updated: {
        environment.etc."resolv.conf".text = "";
        th.target.containers.enable = true;
        th.target.containers.containers.mosquitto = {
            readOnlyRootFS = false; env = {
                PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
                VERSION = "2.0.14";
                DOWNLOAD_SHA256 = "d0dde8fdb12caf6e2426b4f28081919a2fce3448773bdb8af0d3cd5fe5776925 ";
                GPG_KEYS = "A0D6EEA1DCAE49A635A3B2F0779B22DFB3E717B7";
                LWS_VERSION = "4.2.1";
                LWS_SHA256 = "842da21f73ccba2be59e680de10a8cce7928313048750eb6ad73b6fa50763c51";
            };
            command = [ "/docker-entrypoint.sh" "/usr/sbin/mosquitto" "-c" "/mosquitto/config/mosquitto.conf" ];
            rootFS = [
                (lib.th.extract-docker-image pkgs (pkgs.dockerTools.pullImage (if (!updated) then {
                    imageName = "eclipse-mosquitto"; finalImageTag = "2.0.14";
                    imageDigest = "sha256:b5f3829be419e03d7dba8cf4a5870de64c702f840360386f6b856134300b0d15";
                    sha256 = "1f9340595livsl4d934841l88qwkln2kcchcbg99qx6b20v0y094";
                } else {
                    imageName = "eclipse-mosquitto"; finalImageTag = "2.0.15";
                    imageDigest = "sha256:c043073ba24de67a1728a4e0755ebd8ef68ae9dd60d0d9886b15c955df5558b0";
                    sha256 = "064qp9cz225sx8sycrr7ndg6zhqw9kplrp8gnx6w483sq4fzvz9z";
                })))
                # should pass »--as-pid2« to systemd-nspawn, but that has some implications as well
            ];
        };
        th.target.containers.containers.zigbee2mqtt = {
            readOnlyRootFS = false; env = {
                PATH = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";
                NODE_VERSION = "16.14.2";
                YARN_VERSION = "1.22.18";
            }; workingDir = "/app";
            command = [ "/usr/local/bin/docker-entrypoint.sh" "/sbin/tini" "--" "node" "index.js" ];
            rootFS = [
                (lib.th.extract-docker-image pkgs (pkgs.dockerTools.pullImage (if (!updated) then {
                    imageName = "koenkk/zigbee2mqtt"; finalImageTag = "1.25.0";
                    imageDigest = "sha256:599b31ca43edf702763bd834b9e8b14b62ef7eed8512947d8ca27271cbbe367e";
                    sha256 = "11cimbc87y598caa303fpi3i03a2136z4n2yylljgqf43rm3ccha";
                } else {
                    imageName = "koenkk/zigbee2mqtt"; finalImageTag = "1.25.2";
                    imageDigest = "sha256:94b3a150bb3733cda15ffa3541eea75fe43d8882573b09d8b294930be3975fca";
                    sha256 = "199kj2fzf7fwrkcr11afd1rvyb79f56hpy2b2qzwagjqi2ghisxm";
                })))
            ];
            sshKeys.root = [ (lib.readFile "${inputs.self}/utils/res/ssh_testkey_2.pub") ];
        };
        containers.zigbee2mqtt.allowedDevices = [ { node = "/dev/ttyACM0"; modifier = "rw"; } ];
        systemd.services."container@zigbee2mqtt".serviceConfig.Restart = lib.mkForce "no";
    };

    updateSystemdOverlay = let
        updated-nixpkgs = pkgs.applyPatches {
            name = "nixpkgs-systemd"; src = "${inputs.old-nixpkgs}";
            patches = [
                (pkgs.fetchpatch2 { url = "https://github.com/NixOS/nixpkgs/commit/eeff6c493373d3fff11421b55309fab6a1d4ec7d.diff?full_index=1"; sha256 = "sha256-1o/Y4hStyGxUDEQArobqEh+ofH4mXecty9l3ep9Htf8="; }) # (irrelevant, but required for the next patch)
                (pkgs.fetchpatch2 { url = "https://github.com/NixOS/nixpkgs/commit/a14d1a2e7e8c19087897bc646a37f50096b736b1.diff?full_index=1"; sha256 = "sha256-d0vUlB0uTx7+cLzl2FtmZGQNRK396TmxK9QdUZijp6I="; }) # systemd: 250.4 -> 251.3
            ];
        };
    in (final: prev: {
        systemd = final.callPackage "${updated-nixpkgs}/pkgs/os-specific/linux/systemd/default.nix" { # (the exact same call to construct systemd as in the default package set, except for the updated sources)
            util-linux = final.util-linuxMinimal;
            gnupg = final.callPackage "${inputs.old-nixpkgs}/pkgs/tools/security/gnupg/23.nix" { enableMinimal = true; guiSupport = false; pcsclite = null; sqlite = null; pinentry = null; adns = null; gnutls = null; libusb1 = null; openldap = null; readline = null; zlib = null; bzip2 = null; };
        };
    });

    minimal = rec {
        # The base generation for all updates:
        old = prep-system inputs.self.nixosConfigurations."old:x64-minimal";
        # Update after 75 days of nixpkgs (stable) changes:
        new = prep-system inputs.self.nixosConfigurations."new:x64-minimal";
        # Artificial update after changing the (input) hash of glibc:
        clb = test.overrideBase old ({ config, ... }: {
            nixpkgs.overlays = lib.mkIf (!config.system.build?isVmExec) [ (final: prev: {
                glibc = prev.glibc.overrideAttrs (old: { trivialChange = 42 ; });
            }) ];
            #system.nixos.tags = [ "glibc" ]; # this would be an additional modification
        });
        # Update of explicitly updating applications (MQTT, natively or as container) or systemd:
        app = test.override old ({ config, ... }: { imports = let
            withMqtt = lib.elem "withMqtt" config.system.nixos.tags;
            withOci = lib.elem "withOci" config.system.nixos.tags;
        in [ ({ pkgs, ... }: {
            nixpkgs.overlays = lib.mkIf (!withMqtt && !withOci) (lib.mkBefore [ updateSystemdOverlay ]);
            system.build.update-app = true;
            # (with »testing.overrideBase«, it should work to move the »services.{mosquitto,zigbee2mqtt}.package = ...« here)
        }) ]; });

        # »old« on the iPI for manual testing:
        rpi = test.override (prep-system inputs.self.nixosConfigurations."old:rpi-minimal") {
            th.hermetic-bootloader.uboot.env.bootdelay = lib.mkForce "0";
            #nixpkgs.overlays = [ (final: prev: { systemd = (prev.systemd.override { withAnalyze = true; }); }) ];
            wip.services.dropbear.rootKeys = lib.readFile "${inputs.self}/utils/res/ssh_testkey_1.pub";
        };

        # »rpi« cross-compiled from x64:
        "x64:rpi" = test.overrideBase rpi ({
            nixpkgs = lib.mkForce { localSystem.system = "x86_64-linux"; crossSystem.system = "aarch64-linux"; };
        });
    };

    systems = {
        minimal = minimal;

        noKernel = lib.mapAttrs (k: system: { config = (test.override system {
            system.extraSystemBuilderCmds = ''rm -f $out/kernel $out/kernel-modules''; # (»boot.kernel.enable« is 22.11+)
            system.nixos.tags = [ "noKernel" ];
        }).config.specialisation.default.configuration; }) minimal;

        withOci = (lib.mapAttrs (k: system: test.override system ({ config, ... }: {
            specialisation.mqtt.configuration = mqttOciConfig (config.system.build.update-app or false);
            system.nixos.tags = [ "withOci" ];
        })) minimal);

        withMqtt = (lib.mapAttrs (k: system: test.override system ({ config, ... }: {
            specialisation.mqtt.configuration = mqttNixConfig (config.system.build.update-app or false);
            system.nixos.tags = [ "withMqtt" ];
        })) minimal);

        withUpdate = (lib.mapAttrs (k: system: test.override system ({ config, ... }: {
            specialisation.mqtt-old.configuration = mqttNixConfig false;
            specialisation.mqtt-new.configuration = mqttNixConfig true;
            system.nixos.tags = [ "withUpdate" ];
        })) minimal);

        withApps = (lib.mapAttrs (k: system: test.override system {
            imports = map (_:_.nixos or { }) (lib.attrValues applications);
            system.nixos.tags = [ "withApps" ];
        }) minimal);
    };

    installers = lib.mapAttrs (k1: v: lib.mapAttrs (k2: system: pkgs.writeShellScriptBin "scripts-${k2}-${k1}" ''exec ${lib.installer.writeSystemScripts { inherit system pkgs; }} "$@"'') v) systems;

in { inherit systems installers; script = test.useTsBlock { inherit pkgs dirname; filename = "nix_store_send.nix.md"; ticks = "````"; context = {
    inherit dirname; pkgs = {
        inherit (pkgs) bash coreutils time zstd;
        nix = inputs.nix.packages.${pkgs.system}.nix;
    };
    systems = lib.mapAttrs (k: systems: toplevels (builtins.removeAttrs systems [ "rpi" "x64:rpi" ])) (builtins.removeAttrs systems [ "withApps" "withUpdate" ]);
}; }; }
/*# end of nix
```


## Update Evaluation

The Nix code above defined some (sets of) systems, which this TypeScript code can now run update tests on.
This creates the file `../out/nix_store_send.csv`, which we then use to generate plots and draw conclusions.

````ts
const { spawnSync, } = require('child_process'), FS = require('fs');
console.error(__filename, context);

const nix = context.pkgs.nix +'/bin/nix';
const nixArgs = [ '--extra-experimental-features', 'nix-command', ];
const sendArgs = [ ...nixArgs, 'store', 'send', '--json', ];
function nixStoreSend(...args) {
    console.log('+', nix, ...sendArgs, '--dry-run',  ...args);
    const timeVars = 'U S e P M'.split(' ');
    const cmd = context.pkgs.bash +'/bin/bash'; args = [ '-c', `
        ${context.pkgs.time}/bin/time -f '%${timeVars.join('|%')}' -- ${nix} ${sendArgs.join(' ')} --append-data ${args.join(' ')} |
        ${context.pkgs.zstd}/bin/zstd |
        ${context.pkgs.coreutils}/bin/wc -c
    `, ];
    //console.log('+', cmd, ...args);
    let { error, stdout, stderr, } = spawnSync(
        cmd, args, { maxBuffer: 1024 * 1024 * 1024, }
    ); if (error) { throw error; }
    stderr = stderr.toString(); stdout = stdout.toString();
    const { 0: timeString, } = (/(?<=[}])[^}]*$/).exec(stderr) || [ '' ];
    const time = Object.fromEntries(timeString.replace(/\n$/, '').split('|').map((v, i) => [ timeVars[i], v, ]));
    const json = stderr.slice(0, -timeString.length);
    try { return { ...JSON.parse(json), time, compressedSize: +stdout, }; } catch (error) {
        console.error(`Last 400 chars from stderr: `, stderr.slice(-400)); throw error;
    }
}

function flattenScript(script, ret = i) {
    script.forEach(i => { if (Array.isArray(i[i.length - 1], ret)) { flattenScript(i); } else { ret.push(i); } }); return ret;
}

const updates = [
    { before: 'old', after: 'new', },
    { before: 'old', after: 'clb', },
    { before: 'old', after: 'app', },
];
const chunkingOptions = [
    { description: 'none', flags: [ '--no-scan-refs', ], },
    { description: 'refs', flags: [ ], },
    { description: '64',  flags: [ '--no-scan-refs', '--max-chunk-size', '64',  ], },
    { description: '128', flags: [ '--no-scan-refs', '--max-chunk-size', '128', ], }, //
    { description: '256', flags: [ '--no-scan-refs', '--max-chunk-size', '256', ], }, //
    { description: '512', flags: [ '--no-scan-refs', '--max-chunk-size', '512', ], },
    { description: '1k',  flags: [ '--no-scan-refs', '--max-chunk-size', '1k',  ], }, //
    { description: '2k',  flags: [ '--no-scan-refs', '--max-chunk-size', '2k',  ], }, //
    { description: '4k',  flags: [ '--no-scan-refs', '--max-chunk-size', '4k',  ], },
    { description: '8k',  flags: [ '--no-scan-refs', '--max-chunk-size', '8k',  ], }, //
    { description: '16k', flags: [ '--no-scan-refs', '--max-chunk-size', '16k', ], }, //
    { description: '32k', flags: [ '--no-scan-refs', '--max-chunk-size', '32k', ], },
    { description: 'refs+64',  flags: [ '--max-chunk-size', '64',  ], },
    { description: 'refs+128', flags: [ '--max-chunk-size', '128', ], }, //
    { description: 'refs+256', flags: [ '--max-chunk-size', '256', ], }, //
    { description: 'refs+512', flags: [ '--max-chunk-size', '512', ], },
    { description: 'refs+1k',  flags: [ '--max-chunk-size', '1k',  ], }, //
    { description: 'refs+2k',  flags: [ '--max-chunk-size', '2k',  ], }, //
    { description: 'refs+4k',  flags: [ '--max-chunk-size', '4k',  ], },
    { description: 'refs+8k',  flags: [ '--max-chunk-size', '8k',  ], }, //
    { description: 'refs+16k', flags: [ '--max-chunk-size', '16k', ], }, //
    { description: 'refs+32k', flags: [ '--max-chunk-size', '32k', ], },
    { description: 'refs+strings', flags: [ '--skip-path-suffix', ], },
    { description: 'refs+4k+strings', flags: [ '--max-chunk-size', '4k', '--skip-path-suffix', ], },
    { description: 'bsd+none', flags: [ '--use-bsdiff', '--no-scan-refs', ], },
    { description: 'bsd+refs', flags: [ '--use-bsdiff', ], },
    { description: 'bsd+64',  flags: [ '--use-bsdiff', '--no-scan-refs', '--max-chunk-size', '64',  ], },
    { description: 'bsd+128', flags: [ '--use-bsdiff', '--no-scan-refs', '--max-chunk-size', '128', ], }, //
    { description: 'bsd+256', flags: [ '--use-bsdiff', '--no-scan-refs', '--max-chunk-size', '256', ], }, //
    { description: 'bsd+512', flags: [ '--use-bsdiff', '--no-scan-refs', '--max-chunk-size', '512', ], },
    { description: 'bsd+1k',  flags: [ '--use-bsdiff', '--no-scan-refs', '--max-chunk-size', '1k',  ], }, //
    { description: 'bsd+2k',  flags: [ '--use-bsdiff', '--no-scan-refs', '--max-chunk-size', '2k',  ], }, //
    { description: 'bsd+4k',  flags: [ '--use-bsdiff', '--no-scan-refs', '--max-chunk-size', '4k',  ], },
    { description: 'bsd+8k',  flags: [ '--use-bsdiff', '--no-scan-refs', '--max-chunk-size', '8k',  ], }, //
    { description: 'bsd+16k', flags: [ '--use-bsdiff', '--no-scan-refs', '--max-chunk-size', '16k', ], }, //
    { description: 'bsd+32k', flags: [ '--use-bsdiff', '--no-scan-refs', '--max-chunk-size', '32k', ], },
    { description: 'bsd+refs+64',  flags: [ '--use-bsdiff', '--max-chunk-size', '64',  ], },
    { description: 'bsd+refs+128', flags: [ '--use-bsdiff', '--max-chunk-size', '128', ], }, //
    { description: 'bsd+refs+256', flags: [ '--use-bsdiff', '--max-chunk-size', '256', ], }, //
    { description: 'bsd+refs+512', flags: [ '--use-bsdiff', '--max-chunk-size', '512', ], },
    { description: 'bsd+refs+1k',  flags: [ '--use-bsdiff', '--max-chunk-size', '1k',  ], }, //
    { description: 'bsd+refs+2k',  flags: [ '--use-bsdiff', '--max-chunk-size', '2k',  ], }, //
    { description: 'bsd+refs+4k',  flags: [ '--use-bsdiff', '--max-chunk-size', '4k',  ], },
    { description: 'bsd+refs+8k',  flags: [ '--use-bsdiff', '--max-chunk-size', '8k',  ], }, //
    { description: 'bsd+refs+16k', flags: [ '--use-bsdiff', '--max-chunk-size', '16k', ], }, //
    { description: 'bsd+refs+32k', flags: [ '--use-bsdiff', '--max-chunk-size', '32k', ], },
    { description: 'bsd+refs+strings', flags: [ '--use-bsdiff', '--skip-path-suffix', ], },
    { description: 'bsd+refs+4k+strings', flags: [ '--use-bsdiff', '--max-chunk-size', '4k', '--skip-path-suffix', ], },
    { description: 'bsd-nar+none', flags: [ '--bsdiff-nars', '--no-scan-refs', ], },
];

const results = [ ];
for (const systemType of Object.keys(context.systems)) { // [ "withMqtt" ]
    for (const { before, after, } of updates) {
        for (const { description, flags, } of chunkingOptions) { try {
            console.log(`(${systemType}) ${before} -> ${after}: ${description}`);
            const { stats, time, compressedSize, } = nixStoreSend(
                ...flags, '--',
                context.systems[systemType][before],
                context.systems[systemType][after],
            );
            const file_s = stats.reg_s + stats.exec_s + stats.sym_s + stats.dir_s;
            const trans_s = stats.script_s + stats.copy_s + stats.patch_s;
            results.push({
                systemType, before, after, chunkingType: description,
                file_s, trans_s, trans_p: trans_s / file_s * 100,
                comp_s: compressedSize, comp_p: compressedSize / file_s * 100,
                ...stats,
                ...Object.fromEntries(Object.entries(time).map(([ k, v, ]) => [ `time_${k}`, +(k == 'P' ? v.slice(0, -1) : v), ])),
            });
            //console.log(results[results.length - 1]);
        } catch (e) { console.error(e); } }
    }
}

//try { FS.mkdirSync(process.env.out); } catch { } try { if (+process.env.SUDO_UID && +process.env.SUDO_GID) { FS.chownSync(process.env.out, +process.env.SUDO_UID, +process.env.SUDO_GID); } } catch (e) { console.error(e); }
FS.writeFileSync(process.env.out +'/nix_store_send.csv', require(`${context.dirname}/../lib/util.ts`).CSV.stringify({
    header: Object.keys(results[0]), records: results, stringify: { tabPrefix: false, },
}) +'\n');

process.stdout.write(require(`${context.dirname}/../lib/util.ts`).TXT.stringify({
    columns: {
        systemType: '^System', before: '^Before', after: '^After', file_s: '$ … Size',
        chunkingType: '^Chunking', trans_s: '$Transfer', trans_p: '$ … %',
        comp_s: '$ … Compressed', comp_p: '$ … %',
        time_e: '$ t(s)',
        time_M: '$ MaxRes',
        script_s: '$Script',
        copy_c: '$Copied', copy_s: '$ - Chunks',
        patch_c: '$Copied', patch_s: '$ - Patches',
        slice_c: '$Reused', slice_s: '$ - Chunks',
        link_c: '$Reused', link_s: '$ - Files',
        ref_c: '$Refer', ref_s: '$ -en'+'ces',
    },
    stringify(value, key) { switch (true) {
        case (typeof value === 'number' && key.endsWith('_s')): return ((value + 512) / 1024 / 1000).toFixed(3).replace('.', ',') +'KiB';
        case (typeof value === 'number' && key.endsWith('_p')): return (value).toFixed(2) +'%';
        case (key == 'time_e'): return value.toFixed(2);
        case (key == 'time_M'): return ((value + 512) / 1024 / 1000).toFixed(3).replace('.', ',') +'MiB';
        case (key == 'before' || key == 'after'): return value.replace(/_/g, ' ');
        default: return value +'';
    } },
    entries: results,
    separator: '  ', delimiter: '\n',
}) +'\n');
````


## System Testing

Boot the x64 version in qemu:
```bash
 nix run .'#'checks.x86_64-linux.nix_store_send.passthru.installers.withMqtt.old -- run-qemu --efi --install=always
 nix run .'#'checks.x86_64-linux.nix_store_send.passthru.installers.withOci.old -- run-qemu --efi --install=always

 # no completion, history or editing, so here are all the commands I used:
 next-boot mqtt && reboot
 systemctl status container@mosquitto.service
 systemctl cat container@mosquitto.service
 systemctl restart container@mosquitto.service
 journalctl -b -f -u container@mosquitto.service
 journalctl -b -f --lines=80 -u container@mosquitto.service
 machinectl shell mosquitto
 systemctl status
 systemctl list-units --failed
 systemctl status mosquitto.service
 systemctl cat mosquitto.service
 journalctl -b -f -u mosquitto.service

 systemctl status container@zigbee2mqtt.service
 systemctl restart container@zigbee2mqtt.service
 journalctl -b -f -u container@zigbee2mqtt.service
 journalctl -b -f --lines=80 -u container@zigbee2mqtt.service
 machinectl shell zigbee2mqtt
 systemctl status zigbee2mqtt.service
 systemctl restart zigbee2mqtt.service
 systemctl cat zigbee2mqtt.service
 journalctl -b -f -u zigbee2mqtt.service
 journalctl -b -f --lines=80 -u zigbee2mqtt.service
 systemctl show --property=StateChangeTimestampMonotonic --value zigbee2mqtt.service
 systemctl show --property=StateChangeTimestamp --value zigbee2mqtt.service
```

Install e.g the rPI version of a system to a microSD card (on an x64 system):
```bash
 nix run .'#'checks.x86_64-linux.nix_store_send.passthru.installers.withMqtt.rpi -- install-system /dev/mmcblk0

 ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i utils/res/ssh_testkey_1 root@192.168.8.85
 next-boot mqtt && reboot
 systemctl show --property=StateChangeTimestampMonotonic --value container@zigbee2mqtt.service
 machinectl --quiet shell zigbee2mqtt /run/current-system/sw/bin/systemctl show --property=ActiveEnterTimestampMonotonic --value zigbee2mqtt.service

 systemctl show --property=StateChangeTimestamp --value container@zigbee2mqtt.service
 systemctl show --property=StateChangeTimestampMonotonic --value container@mosquitto.service
 systemctl show --property=ActiveEnterTimestampMonotonic --value container@zigbee2mqtt.service
 systemctl show --property=ActiveEnterTimestampMonotonic --value container@mosquitto.service
 machinectl shell zigbee2mqtt
 machinectl shell mosquitto
 systemctl show --property=StateChangeTimestampMonotonic --value zigbee2mqtt.service
 systemctl show --property=ActiveEnterTimestampMonotonic --value multi-user.target
```

And here is the semi-automated boot performance test:
```bash
 # Install the system to a microSD card:
 nix run .'#'checks.x86_64-linux.nix_store_send.passthru.installers.withUpdate.rpi -- install-system /dev/mmcblk0 # (adjust the /dev/* path as needed)
 #nix run .'#'checks.x86_64-linux.nix_store_send.passthru.installers.withUpdate.x64:rpi -- install-system /dev/mmcblk0 # or this for the cross-compiled version (not recommended, also does not compile ...)
 # Then boot the system on a rPI4, and make sure that »$ssh« works to log in and that the PI logs to this host's »/dev/ttyUSB0«:
 mkdir -p out/logs ; LC_ALL=C nix-shell -p openssh -p tio -p moreutils --run bash # open a shell with the required programs, then in that shell:
 ssh='ssh -o LogLevel=QUIET -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i utils/res/ssh_testkey_1 root@192.168.8.85'
 function wait4boot () { for i in $(seq 20) ; do sleep 1 ; if $ssh -- true &>/dev/null ; then return 0 ; fi ; printf . ; done ; return 1 ; }
 wait4boot
 ( set -x ; logPid= ; trap '[[ ! $logPid ]] || kill $logPid' EXIT ; for run in $(seq 20) ; do
     target=mqtt-new ; (( run % 2 )) || target=mqtt-old
     [[ ! $logPid ]] || kill $logPid ; logPid=
     log=out/logs/reboot-$(( run - 1 ))-to-$target.txt ; rm -f $log
     sleep infinity | tio --timestamp --timestamp-format 24hour-start /dev/ttyUSB0 --log --log-strip --log-file $log >/dev/null & logPid=$!
     $ssh -- "echo 'next-boot $target' >/dev/ttyS1 ; set -x ; next-boot $target && reboot" || true
     wait4boot || exit ; echo
 done ) || { echo 'oh noo' ; false ; }
```
`LC_ALL=C nix-shell -p openssh -p tio -p moreutils --run 'tio --timestamp --timestamp-format 24hour-start /dev/ttyUSB0' # exit with ctrl-t q`

Test to "reboot" with kexec (but that does not work on the iPI):
```bash
 # x64
 type=bzImage
 linux=/nix/store/s9x83hgh7bgsz0kyfg3jvb39rj678k5n-linux-5.15.36/bzImage
 initrd=/nix/store/sdvc543ysdw3720cnmr44hcxhkm9gv4h-initrd-linux-5.15.36/initrd
 options='init=/nix/store/4m8v2bjbpdwnbfgwrypr8rnkia919hnk-nixos-system-x64-minimal-test1-withMqtt-22.05.20220505.c777cdf/init boot.shell_on_fail console=ttyS0 panic=10 hung_task_panic=1 hung_task_timeout_secs=30 loglevel=4'

 # rpi
 type=Image
 linux=/nix/store/1qqjvky6dla1rvr2aw1bvclwzr50byi7-linux-5.15.36/Image
 initrd=/nix/store/2xhayk1adfajwcbn1zzdmnxpv1mc1blb-initrd-linux-5.15.36/initrd
 options='init=/nix/store/w7w00z062llgzcxai12zwg7psrfn1zzp-nixos-system-rpi-minimal-test1-withOci-22.05.20220505.c777cdf/init boot.shell_on_fail console=tty1 panic=10 hung_task_panic=1 hung_task_timeout_secs=30 loglevel=4'
 fdtdir=/nix/store/f7647aw7vpvjiw7bpz7h47wgigjfm592-device-tree-overlays

 kexec --load --type=$type $linux --initrd=$initrd --command-line="$options" && systemctl kexec
```

*/
