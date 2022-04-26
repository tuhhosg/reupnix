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

}) ({ ## Temporary Test Stuff

    imports = [ (lib.mkIf false { # Just to prove that this can be installed very small:
        installer.disks.primary.size = "256M"; installer.disks.primary.alignment = 8;
        installer.partitions."boot-${builtins.substring 0 8 (builtins.hashString "sha256" config.networking.hostName)}".size = lib.mkForce "${toString (32 + 1)}M"; # VBox EFI only supports FAT32
        th.target.fs.dataSize = "1K"; fileSystems."/data" = lib.mkForce { fsType = "tmpfs"; device = "tmpfs"; }; # don't really need /data
        fileSystems."/system".formatOptions = lib.mkForce "-E nodiscard"; # (remove »-O inline_data«)
    }) ];

    services.getty.autologinUser = "root"; users.users.root.hashedPassword = "$5$UqX6IreDL98q0PpD$rZRHDlu8LmorOHNCWo/2SQNQewQ.G/r/8XAUNGSxuo2"; # .password = "root";

    boot.kernelParams = [ "boot.shell_on_fail" ];

    boot.initrd.preLVMCommands = lib.mkIf false (let
        inherit (config.system.build) extraUtils;
        order = 501; # after console initialization, just before opening luks devices
    in lib.mkOrder order ''
        setsid ${extraUtils}/bin/ash -c "exec ${extraUtils}/bin/ash < /dev/$console >/dev/$console 2>/dev/$console"
    '');

    #services.openssh.enable = true;
    th.dropbear.enable = true;
    th.dropbear.rootKeys = [ "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQC+y3pbsUopXWSWVz+sowoMPTWv+u9Qj9aEl20NUN1LrKxduUv/fijmOyui92ZdTYJEu1oa5+V5jbxxlqNDn51yuwXXCxnIwFgh/aSl34Mc86HrjH73kZonya26jfCBE/7Mn9rppUmpkTt0Dk13Y1gnKp0OvuukEQ+Fa5ZxPLtyZ9d3zYDKIBbwNhISOHlllj8jgEMgGNNDGS7EdFh9AEnKG9d8s4+zTlHEXTom0srr4GBrRcG8qlV6DEcHB/aS7hhI5lA79H9AFWd1PjTV7ZUvX9sLsfRitcmQy2psicDxlagA15Lm/pLuf11t+IIO6bv9EG1cCAvkrGqnGqHLCPFYIW0rKyxD2IRq1ZG4+sbyQlgJiACw1WPiJkOXK88hmjlvwKGx4i8bk2bkXgcmxEHtd0rl+zsSMaZnNltaaGae7DVPKEYhn/sx+hzPpdpz7nhNs/OmN1Y61Zi8J8NHyBKWJ+lQSpV7AY8f2VNKvTFPdXzZmTYd4xVd7saGCa9235oqHX54rZ2zXZaj24zncnxhsvvKkLHeeYbr8knSZNDVfqCCzrm6FTV8aQ5M+QJwfnjVW+TQ/2hEnM1Jb4qbAylJfGY+LHZC9tysRyMwStvnB2+td4HX4hjO75CWbDsW6RLsXQjuzMNAwcGhftA9rnV8azIVX9PD4FYSadPptwuOsw== gpg_rsa.niklas@gollenstede.net" ];


})  ]; }
