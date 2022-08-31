dirname: inputs: { config, pkgs, lib, name, ... }: let inherit (inputs.self) lib; in let
    suffix = builtins.elemAt (builtins.match ''x64(-(.*))?'' name) 1;
    flags = if suffix == null then [ ] else lib.splitString "-" suffix; hasFlag = flag: builtins.elem flag flags;
in { imports = [ ({ ## Hardware

    system.stateVersion = "22.05";

    th.hermetic-bootloader.loader = "systemd-boot";

    boot.kernelParams = [ "console=ttyS0" ];
    networking.interfaces.ens3.ipv4.addresses = [ { # vBox: enp0s3 ; qemu: ens3
        address = "10.0.2.15"; prefixLength = 24;
    } ];
    networking.defaultGateway = "10.0.2.2";
    networking.nameservers = [ "1.1.1.1" ]; # [ "10.0.2.3" ];

    th.minify.shrinkKernel.usedModules = ./minify.lsmod;


}) (lib.mkIf (hasFlag "minimal") { ## Super-minification

    # Just to prove that this can be installed very small (the »/system« partition gets ~170MiB):
    wip.fs.disks.devices.primary.size = "256M"; wip.fs.disks.devices.primary.alignment = 8;
    th.hermetic-bootloader.slots.size = lib.mkForce "${toString (32 + 1)}M"; # VBox EFI only supports FAT32
    th.target.fs.dataSize = "1K"; fileSystems."/data" = lib.mkForce { fsType = "tmpfs"; device = "tmpfs"; }; # don't really need /data
    fileSystems."/system".formatOptions = lib.mkForce "-E nodiscard"; # (remove »-O inline_data«, which does not work for too small inodes used as a consequence of the tiny FS size)


}) (lib.mkIf true { ## Temporary Test Stuff

    services.getty.autologinUser = "root"; users.users.root.hashedPassword = "${lib.wip.removeTailingNewline (lib.readFile "${inputs.self}/utils/res/root.sha256-pass")}"; # .password = "root";

    boot.kernelParams = [ "boot.shell_on_fail" ]; wip.base.panic_on_fail = false;

    wip.services.dropbear.rootKeys = [ ''${lib.readFile "${inputs.self}/utils/res/niklas-gollenstede.pub"}'' ];
    wip.services.dropbear.hostKeys = [ ../../utils/res/dropbear_ecdsa_host_key ];

    boot.initrd.preLVMCommands = lib.mkIf false (let
        inherit (config.system.build) extraUtils;
        order = 501; # after console initialization, just before opening luks devices
    in lib.mkOrder order ''
        setsid ${extraUtils}/bin/ash -c "exec ${extraUtils}/bin/ash < /dev/$console >/dev/$console 2>/dev/$console"
    '');


}) (lib.mkIf (!hasFlag "minimal") { ## Bloat Test Stuff

    th.minify.enable = lib.mkForce false; th.minify.etcAsOverlay = lib.mkForce false;
    environment.systemPackages = lib.mkIf ((suffix == null) || (hasFlag "debug")) [ pkgs.curl pkgs.nano pkgs.gptfdisk pkgs.tmux pkgs.htop pkgs.libubootenv ];


}) ]; }
