dirname: inputs: { config, pkgs, lib, name, ... }: let lib = inputs.self.lib.__internal__; in let
    flags = lib.tail (lib.splitString "-" name); hasFlag = flag: builtins.elem flag flags;
    hash = builtins.substring 0 8 (builtins.hashString "sha256" name);
in { imports = [ ({ ## Hardware

    nixpkgs.hostPlatform = "aarch64-linux";
    system.stateVersion = "22.05";

    setup.disks.devices.primary.size = 31914983424; #31657558016; #31914983424; #64021856256; #63864569856;

    ## Firmware/bootloader:
    th.hermetic-bootloader.loader = "uboot-extlinux";
    th.hermetic-bootloader.uboot.base = pkgs.uboot-imx.override { platform = lib.toLower config.nxp.imx8-boot.soc; };
    th.hermetic-bootloader.uboot.mmcDev = 1;
    th.hermetic-bootloader.uboot.env = config.nxp.imx8-boot.uboot.envVars;
    th.hermetic-bootloader.uboot.extraConfig = [ "CONFIG_IMX_WATCHDOG=y" ]; # required on i.MX devices (up to apparently including i.MX8) to enable the watchdog hardware
    nxp.imx8-boot.uboot.package = config.th.hermetic-bootloader.uboot.result;
    nxp.imx8-boot.enable = true; nxp.imx8-boot.soc = "iMX8MP";
    nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "firmware-imx" ];
    boot.loader.generic-extlinux-compatible.enable = lib.mkForce false;
    setup.boot.enable = lib.mkForce false;
    # The i.MX expects the boot image starting at sector 64. The multiple copies of the GPT would usually conflict with that, so move them:
    th.hermetic-bootloader.extraGptOffset = 3 * 1024 * 2; # (3M in sectors)
    setup.disks.partitions."bootloader-${hash}" = lib.mkForce null;
    boot.kernelParams = [ "console=ttymxc1" ];

    th.minify.shrinkKernel.baseKernel = pkgs.linux-imx_v8;
    #th.minify.shrinkKernel.usedModules = ./minify.lsmod; # (There are build errors in at least »drivers/usb/typec/mux/gpio-switch« (undefined symbols).)

    ## Networking:
    networking.interfaces.eth0.ipv4.addresses = [ {
        address = "192.168.8.86"; prefixLength = 24;
    } ];
    networking.defaultGateway = "192.168.8.1";
    networking.nameservers = [ "1.1.1.1" ];

    #boot.kernelPackages = lib.mkForce pkgs.linuxPackages; # building the i.MX kernel on x64 is quite time consuming
    disableModule."tasks/swraid.nix" = true; # The kernel is missing modules required by this.

    system.build.vmExec = lib.mkForce null; # (NixOS thinks that) the »pkgs.linux-imx_v8« kernel is not compatible with the installer VM.


}) (lib.mkIf true { ## Test Stuff

    services.getty.autologinUser = "root"; users.users.root.hashedPassword = "${lib.fun.removeTailingNewline (lib.readFile "${inputs.self}/utils/res/root.sha256-pass")}"; # .password = "root";

    boot.kernelParams = [ "boot.shell_on_fail" ]; wip.base.panic_on_fail = false;

    wip.services.dropbear.rootKeys = lib.readFile "${inputs.self}/utils/res/niklas-gollenstede.pub";
    wip.services.dropbear.hostKeys = [ ../../utils/res/dropbear_ecdsa_host_key ];

    boot.initrd.preLVMCommands = lib.mkIf false (let inherit (config.system.build) extraUtils; in ''
        setsid ${extraUtils}/bin/ash -c "exec ${extraUtils}/bin/ash < /dev/$console >/dev/$console 2>/dev/$console"
    '');


}) (lib.mkIf (!hasFlag "minimal") { ## Bloat Test Stuff

    th.minify.enable = lib.mkForce false; th.minify.etcAsOverlay = lib.mkForce false;
    environment.systemPackages = lib.mkIf ((flags == [ ]) || (hasFlag "debug")) [ pkgs.curl pkgs.nano pkgs.gptfdisk pkgs.tmux pkgs.htop pkgs.libubootenv ];


})  ]; }
