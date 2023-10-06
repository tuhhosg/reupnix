/*

# ...


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

    minimal = {
        # »old« on the iPI for manual testing:
        rpi = test.override (prep-system inputs.self.nixosConfigurations."old:rpi-minimal") {
            th.hermetic-bootloader.uboot.env.bootdelay = lib.mkForce "0";
            #nixpkgs.overlays = [ (final: prev: { systemd = (prev.systemd.override { withAnalyze = true; }); }) ];
            wip.services.dropbear.rootKeys = lib.readFile "${inputs.self}/utils/res/ssh_testkey_1.pub";
        };
    };

    systems = {
        withUpdate = (lib.mapAttrs (k: system: test.override system ({ config, ... }: {
            specialisation.mqtt-old.configuration = mqttNixConfig false;
            specialisation.mqtt-new.configuration = mqttNixConfig true;
            system.nixos.tags = [ "withUpdate" ];
        })) minimal);
    };

    installers = lib.mapAttrs (k1: v: lib.mapAttrs (k2: system: pkgs.writeShellScriptBin "scripts-${k2}-${k1}" ''exec ${lib.inst.writeSystemScripts { inherit system pkgs; }} "$@"'') v) systems;

in { inherit systems installers; script = ''
    echo 'no-op' ; exit true
''; }
/*# end of nix
```


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
