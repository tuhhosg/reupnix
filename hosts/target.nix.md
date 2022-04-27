/*

# Target/Production Host

The configuration(s) that will run on the embedded target device(s).


## Installation

To prepare the virtual machine disk, as `sudo` user with `nix` installed, run:
```bash
 ( cd /etc/nixos && nix run '.#target' -- sudo install-system /home/$(id -un)/vm/disks/target.img && sudo chown $(id -un): /home/$(id -un)/vm/disks/target.img )
```
Then as the user that is supposed to run the VM(s):
```bash
 ( cd /etc/nixos && nix run '.#target' -- register-vbox /home/$(id -un)/vm/disks/target.img )
```
And manage the VM(s) using the UI or the commands printed:
```bash
# VM info:
 VBoxManage showvminfo nixos-target
# start VM:
 VBoxManage startvm nixos-target --type headless
# kill VM:
 VBoxManage controlvm nixos-target poweroff
# create TTY:
 socat UNIX-CONNECT:/run/user/$(id -u)/nixos-target.socket PTY,link=/run/user/$(id -u)/nixos-target.pty
# connect TTY:
 screen /run/user/$(id -u)/nixos-target.pty
# screenshot:
 ssh user@laptop VBoxManage controlvm nixos-target screenshotpng /dev/stdout | display
```


## Implementation

```nix
#*/# end of MarkDown, beginning of NixOS config flake input:
dirname: inputs: { config, pkgs, lib, name, ... }: let inherit (inputs.self) lib; in let
    #suffix = builtins.head (builtins.match ''target-(.*)'' name);
in { imports = [ ({ ## Hardware
    #preface.instances = [ ... ];

    preface.hardware = "x86_64"; system.stateVersion = "22.05";

    boot.loader.systemd-boot.enable = true; boot.loader.grub.enable = false;
    th.target.fs.enable = true; th.target.fs.vfatBoot = "/boot";

    th.base.enable = true; th.minify.enable = true;

    networking.interfaces.enp0s3.ipv4.addresses = [ {
        address = "10.0.2.15"; prefixLength = 24;
    } ];
    networking.defaultGateway = "10.0.2.2";
    networking.nameservers = [ "1.1.1.1" ]; # [ "10.0.2.3" ];


}) ({ ## Different Container Setups as »specialisation«s

    th.target.specs.enable = true;
    specialisation.test1.configuration = {
        th.target.specs.name = "test1";
        # TODO: the actual differences in this configuration

    };

    th.target.containers.enable = true;
    th.target.containers.containers.native = {
        modules = [ ({ config, pkgs, ... }: {

            systemd.services.http = {
                serviceConfig.ExecStart = "${pkgs.busybox}/bin/httpd -f -v -p 8000 -h ${pkgs.writeTextDir "index.html" ''
                    <!DOCTYPE html>
                    <html><head></head><body>YAY</body></html>
                ''}";
                wantedBy = [ "multi-user.target" ];
                serviceConfig.Restart = "always"; serviceConfig.RestartSec = 5; unitConfig.StartLimitIntervalSec = 0;
                serviceConfig.DynamicUser = "yes";
            };
            networking.firewall.allowedTCPPorts = [ 8000 ];

        }) ];
        sshKeys.root = [ (lib.readFile "${dirname}/../res/ssh_dummy_1.pub") ]; # ssh -o "IdentitiesOnly=yes" -i res/ssh_dummy_1 target -> root@native
    };
    th.target.containers.containers.foreign = {
        rootFS = [
            # printf 'FROM ubuntu:20.04 \nRUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y ubuntu-server busybox' | docker build --pull -t local/ubuntu-server -
            # ( image=local/ubuntu-server ; set -eux ; id=$(docker container create ${image/_\//}) ; trap "docker rm --volumes $id" EXIT ; rm -rrf ../images/$image ; mkdir -p ../images/$image ; cd ../images/$image ; docker export $id | pv | tar x )
            inputs.rootfs-ubuntu-server
            (pkgs.runCommandLocal "layer-prepare-systemd" { } ''
                mkdir -p $out
                ln -sT /usr/lib/systemd/systemd $out/init

                mkdir -p $out/etc/systemd/system/
                printf '[Service]\nExecStart=/bin/busybox httpd -f -v -p 8001 -h /web-root/\n' > $out/etc/systemd/system/http.service
                mkdir -p $out/etc/systemd/system/multi-user.target.wants
                ln -sT ../http.service $out/etc/systemd/system/multi-user.target.wants/http.service
                mkdir -p $out/web-root/ ; printf '<!DOCTYPE html>\n<html><head></head><body>YAY</body></html>\n' > $out/web-root/index.html
            '')
        ];
    };


}) ({ ## Temporary Test Stuff

    environment.systemPackages = [ pkgs.curl pkgs.nano ];

    imports = [ (lib.mkIf false { # Just to prove that this can be installed very small:
        installer.disks.primary.size = "256M"; installer.disks.primary.alignment = 8;
        installer.partitions."boot-${builtins.substring 0 8 (builtins.hashString "sha256" config.networking.hostName)}".size = lib.mkForce "${toString (32 + 1)}M"; # VBox EFI only supports FAT32
        th.target.fs.dataSize = "1K"; fileSystems."/data" = lib.mkForce { fsType = "tmpfs"; device = "tmpfs"; }; # don't really need /data
        fileSystems."/system".formatOptions = lib.mkForce "-E nodiscard"; # (remove »-O inline_data«)
    }) ];

    services.getty.autologinUser = "root"; users.users.root.hashedPassword = "${lib.my.removeTailingNewline (lib.readFile "${dirname}/../res/root-sha256.pass")}"; # .password = "root";

    boot.kernelParams = [ "boot.shell_on_fail" ];

    boot.initrd.preLVMCommands = lib.mkIf false (let
        inherit (config.system.build) extraUtils;
        order = 501; # after console initialization, just before opening luks devices
    in lib.mkOrder order ''
        setsid ${extraUtils}/bin/ash -c "exec ${extraUtils}/bin/ash < /dev/$console >/dev/$console 2>/dev/$console"
    '');

    #services.openssh.enable = true;
    th.dropbear.enable = true;
    th.dropbear.rootKeys = [ ''${lib.readFile "${dirname}/../res/niklas-gollenstede.pub"}'' ];


})  ]; }
