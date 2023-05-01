dirname: inputs: { config, pkgs, lib, name, ... }: let inherit (inputs.self) lib; in let
    flags = lib.tail (lib.splitString "-" name); hasFlag = flag: builtins.elem flag flags;
    isArm = (lib.head (lib.splitString "-" name)) == "arm";
in { imports = [ ({ ## Hardware

    system.stateVersion = "22.05";

    #wip.fs.disks.devices.primary.size = 128035676160;

    boot.kernelParams = [ "console=ttyS0" ];
    networking.interfaces.${if isArm then "enp0s1" else "ens3"}.ipv4.addresses = [ { # vBox: enp0s3 ; qemu-x64: ens3 ; qemu-aarch64: enp0s3
        address = "10.0.2.15"; prefixLength = 24;
    } ];
    networking.defaultGateway = "10.0.2.2";
    networking.nameservers = [ "1.1.1.1" ]; # [ "10.0.2.3" ];

    th.hermetic-bootloader.loader = "systemd-boot";

    th.minify.shrinkKernel.usedModules = ./minify.lsmod;

    boot.initrd.availableKernelModules = [ "virtio_net" "virtio_pci" "virtio_blk" "virtio_scsi" ];


}) (lib.mkIf (false && hasFlag "minimal") { ## Super-minification

    # Just to prove that this can be installed very small (with a 256MiB disk, the »/system« partition gets ~170MiB):
    wip.fs.disks.devices.primary.size = "256M"; wip.fs.disks.devices.primary.alignment = 8;
    th.hermetic-bootloader.slots.size = lib.mkForce "${toString (32 + 1)}M"; # VBox EFI only supports FAT32
    th.target.fs.dataSize = "1K"; fileSystems."/data" = lib.mkForce { fsType = "tmpfs"; device = "tmpfs"; }; # don't really need /data
    #fileSystems."/system".formatOptions = lib.mkForce "-E nodiscard"; # (remove »-O inline_data«, which does not work for too small inodes used as a consequence of the tiny FS size, but irrelevant now that we use a fixed inode size)


}) (lib.mkIf true { ## Temporary Test Stuff

    services.getty.autologinUser = "root"; users.users.root.hashedPassword = "${lib.wip.removeTailingNewline (lib.readFile "${inputs.self}/utils/res/root.${if (builtins.substring 0 5 inputs.nixpkgs.lib.version) == "22.05" then "sha256" else "yescrypt"}-pass")}"; # .password = "root";

    boot.kernelParams = [ "boot.shell_on_fail" ]; wip.base.panic_on_fail = false;

    wip.services.dropbear.rootKeys = lib.readFile "${inputs.self}/utils/res/niklas-gollenstede.pub";
    wip.services.dropbear.hostKeys = [ ../../utils/res/dropbear_ecdsa_host_key ];

    boot.initrd.preLVMCommands = lib.mkIf false (let
        inherit (config.system.build) extraUtils;
        order = 501; # after console initialization, just before opening luks devices
    in lib.mkOrder order ''
        setsid ${extraUtils}/bin/ash -c "exec ${extraUtils}/bin/ash < /dev/$console >/dev/$console 2>/dev/$console"
    '');


}) (lib.mkIf (!hasFlag "minimal") { ## Bloat Test Stuff

    th.minify.enable = lib.mkForce false; th.minify.etcAsOverlay = lib.mkForce false;
    environment.systemPackages = lib.mkIf ((flags == [ ]) || (hasFlag "debug")) [ pkgs.curl pkgs.nano pkgs.gptfdisk pkgs.tmux pkgs.htop pkgs.libubootenv ];

    th.hermetic-bootloader.slots.size = lib.mkIf isArm "256M"; # The default arm kernel is much bigger.


}) ]; }
