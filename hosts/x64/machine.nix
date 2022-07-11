dirname: inputs: { config, pkgs, lib, name, ... }: let inherit (inputs.self) lib; in let
    #suffix = builtins.head (builtins.match ''target-(.*)'' name);
in { imports = [ ({ ## Hardware

    system.stateVersion = "22.05";

    th.hermetic-bootloader.loader = "systemd-boot";

    boot.kernelParams = [ "console=ttyS0" ];
    networking.interfaces.ens3.ipv4.addresses = [ { # vBox: enp0s3 ; qemu: ens3
        address = "10.0.2.15"; prefixLength = 24;
    } ];
    networking.defaultGateway = "10.0.2.2";
    networking.nameservers = [ "1.1.1.1" ]; # [ "10.0.2.3" ];

    #th.minify.shrinkKernel.usedModules = ./minify.lsmod; # TODO


}) (lib.mkIf false { ## Super-minification

    # Just to prove that this can be installed very small:
    wip.fs.disks.devices.primary.size = "320M"; wip.fs.disks.devices.primary.alignment = 8;
    th.hermetic-bootloader.slots.size = lib.mkForce "${toString (32 + 1)}M"; # VBox EFI only supports FAT32
    th.target.fs.dataSize = "1K"; fileSystems."/data" = lib.mkForce { fsType = "tmpfs"; device = "tmpfs"; }; # don't really need /data
    fileSystems."/system".formatOptions = lib.mkForce "-E nodiscard"; # (remove »-O inline_data«) (uhm, why?)


}) (lib.mkIf true { ## Temporary Test Stuff

    services.getty.autologinUser = "root"; users.users.root.hashedPassword = "${lib.wip.removeTailingNewline (lib.readFile "${inputs.self}/utils/res/root.sha256-pass")}"; # .password = "root";

    boot.kernelParams = lib.mkForce [ "console=ttyS0" "boot.shell_on_fail" ]; # the initrd shell will use the last »console=« ; »mkForce« to remove »boot.panic_on_fail«

    wip.services.dropbear.rootKeys = [ ''${lib.readFile "${inputs.self}/utils/res/niklas-gollenstede.pub"}'' ];
    wip.services.dropbear.hostKeys = [ ../../utils/res/dropbear_ecdsa_host_key ];

    boot.initrd.preLVMCommands = lib.mkIf false (let
        inherit (config.system.build) extraUtils;
        order = 501; # after console initialization, just before opening luks devices
    in lib.mkOrder order ''
        setsid ${extraUtils}/bin/ash -c "exec ${extraUtils}/bin/ash < /dev/$console >/dev/$console 2>/dev/$console"
    '');


}) (lib.mkIf true { ## Bloat Test Stuff

    th.minify.enable = lib.mkForce false; th.minify.etcAsOverlay = lib.mkForce false;
    environment.systemPackages = [ pkgs.curl pkgs.nano pkgs.gptfdisk pkgs.tmux pkgs.htop pkgs.libubootenv ];


})  ]; }
